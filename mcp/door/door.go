// Package door is the client of the Tranq app's door: a Unix socket with
// line-delimited JSON, described in mcp/PROTOCOL.md. The app is the only
// writer of the dictionary; this package only carries requests to it.
//
// Every Call opens its own connection, writes one request line, reads one
// answer line and closes. The door allows eight connections at once, a call
// holds one for a few milliseconds, so there is nothing to pool.
package door

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// unavailableText is shown to the human by the agent, so it is written for
// them: the socket is missing when the app is closed or the access switch in
// its settings is off.
const unavailableText = "Откройте Tranq и включите доступ для нейронок в настройках"

// ErrUnavailable means the door could not be reached: the app is not running,
// or it does not listen because AI agent access is off. Its text is meant to
// be read by a human.
var ErrUnavailable = errors.New(unavailableText)

// Refusal is the door's own "no": an answer with ok false. Its text is written
// for a human and goes to the agent as is.
type Refusal struct {
	// Message is the door's error text, in the app language.
	Message string
	// Language is the app language of the answer, ru or en.
	Language string
}

func (r *Refusal) Error() string { return r.Message }

const (
	// bundleID is the app's bundle identifier, used to find the app when the
	// binary does not sit inside a bundle, which is a development build.
	bundleID = "nuter.Tranq"

	defaultTimeout = 15 * time.Second
	defaultWait    = 5 * time.Second
	defaultPoll    = 100 * time.Millisecond

	// maxAnswerBytes bounds one answer line. A full dictionary is well below this.
	maxAnswerBytes = 32 << 20
)

// Client talks to the door of one Tranq app. It is safe for concurrent use.
type Client struct {
	// OpenApp starts the Tranq app. args are the arguments of the macOS `open`
	// command: -g first, to keep the app in the background, then the path of
	// the .app, or -b and a bundle identifier. Tests replace it so that no test
	// opens a real app.
	OpenApp func(ctx context.Context, args ...string) error
	// Timeout bounds one Call, on top of the deadline of its context.
	Timeout time.Duration

	socketPath string
	executable func() (string, error)
	pollEvery  time.Duration
	waitFor    time.Duration
	// logger reports what the agent cannot see, such as a failed launch of the
	// app. It writes to stderr: stdout belongs to the MCP protocol.
	logger *slog.Logger
}

// New returns a client for the socket at socketPath. SocketPath gives the usual one.
func New(socketPath string) *Client {
	return &Client{
		OpenApp:    runOpen,
		Timeout:    defaultTimeout,
		socketPath: socketPath,
		executable: executablePath,
		pollEvery:  defaultPoll,
		waitFor:    defaultWait,
		logger:     slog.New(slog.NewTextHandler(os.Stderr, nil)),
	}
}

// SocketPath returns where the app listens: mcp.sock in the Tranq folder of
// the user's config directory, which on macOS is
// ~/Library/Application Support/Tranq/mcp.sock. The environment variable
// TRANQ_MCP_SOCKET overrides it for development. Without a home directory
// there is no door, and the empty path makes every connection fail with ErrUnavailable.
func SocketPath() string {
	if path := os.Getenv("TRANQ_MCP_SOCKET"); path != "" {
		return path
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "Tranq", "mcp.sock")
}

// Call sends one command and returns the door's data as it came.
//
// A refusal of the door is a *Refusal. A door that cannot be reached is
// ErrUnavailable. Anything else the door says wrong, such as a line that is
// not JSON, is an error whose text a human can read.
func (c *Client) Call(ctx context.Context, cmd string, args any) (json.RawMessage, error) {
	request, err := encodeRequest(cmd, args)
	if err != nil {
		return nil, fmt.Errorf("Не удалось собрать запрос к Tranq: %w", err)
	}

	callCtx := ctx
	if c.Timeout > 0 {
		var cancel context.CancelFunc
		callCtx, cancel = context.WithTimeout(ctx, c.Timeout)
		defer cancel()
	}

	conn, err := (&net.Dialer{}).DialContext(callCtx, "unix", c.socketPath)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrUnavailable
	}
	defer conn.Close()
	// Closing the connection is what unblocks a Write or Read stuck on a silent door.
	defer context.AfterFunc(callCtx, func() { conn.Close() })()

	line, err := exchange(conn, request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if callCtx.Err() != nil {
			return nil, errors.New("Tranq не отвечает. Перезапустите Tranq и повторите.")
		}
		return nil, err
	}
	return parseAnswer(line)
}

// EnsureApp makes sure the door can be reached. When the socket cannot be
// connected it opens the app, in the background, and polls the socket every
// 100 ms for up to five seconds. The launch itself gets the same five seconds.
// When the door does not come up it returns ErrUnavailable.
func (c *Client) EnsureApp(ctx context.Context) error {
	if c.reachable(ctx) {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	args := openArgs("")
	if exe, err := c.executable(); err == nil {
		args = openArgs(exe)
	}
	// A hung `open` must not hold the tool call past the time the door is given to come up.
	openCtx, cancelOpen := context.WithTimeout(ctx, c.waitFor)
	err := c.OpenApp(openCtx, args...)
	cancelOpen()
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		c.logger.Warn("tranq-mcp: could not open the Tranq app", "open_args", args, "error", err)
		// Nothing was started, so there is nothing to wait for.
		return ErrUnavailable
	}

	timeout := time.NewTimer(c.waitFor)
	defer timeout.Stop()
	poll := time.NewTicker(c.pollEvery)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timeout.C:
			return ErrUnavailable
		case <-poll.C:
			if c.reachable(ctx) {
				return nil
			}
		}
	}
}

// reachable reports whether something accepts connections on the socket.
func (c *Client) reachable(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", c.socketPath)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// openArgs returns the arguments of `open` that start the app. The binary
// lives at Tranq.app/Contents/MacOS/tranq-mcp, and the app is found from that
// location. A binary outside a bundle is a development build: the app is then
// found by its bundle identifier. The -g flag starts the app in the
// background: the person is working in their agent and Tranq must not take
// the screen from it.
func openArgs(exe string) []string {
	macOS := filepath.Dir(exe)
	contents := filepath.Dir(macOS)
	app := filepath.Dir(contents)
	if exe != "" && filepath.Base(macOS) == "MacOS" && filepath.Base(contents) == "Contents" && strings.HasSuffix(app, ".app") {
		return []string{"-g", app}
	}
	return []string{"-g", "-b", bundleID}
}

// executablePath is the location of this binary with symlinks resolved, so
// that an agent configured with a link to the binary still finds the bundle.
func executablePath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return exe, nil
}

// runOpen runs the macOS `open` command. Its streams are not inherited:
// stdout and stdin of this process belong to the MCP protocol.
func runOpen(ctx context.Context, args ...string) error {
	return exec.CommandContext(ctx, "/usr/bin/open", args...).Run()
}

func encodeRequest(cmd string, args any) ([]byte, error) {
	if args == nil {
		args = struct{}{}
	}
	body, err := json.Marshal(struct {
		Cmd  string `json:"cmd"`
		Args any    `json:"args"`
	}{cmd, args})
	if err != nil {
		return nil, err
	}
	return append(body, '\n'), nil
}

// exchange writes the request and reads the first line back.
//
// A full door answers at connect time and closes at once, so the request may
// find the connection already closed. A failed write is therefore not the end:
// the line the door left behind is still read and is the answer.
func exchange(conn net.Conn, request []byte) ([]byte, error) {
	_, _ = conn.Write(request)

	reader := bufio.NewReader(io.LimitReader(conn, maxAnswerBytes))
	line, err := reader.ReadBytes('\n')
	if err != nil && err != io.EOF {
		return nil, errors.New("Tranq оборвал соединение, не ответив. Повторите запрос.")
	}
	if err == io.EOF && len(line) >= maxAnswerBytes {
		return nil, errors.New("Ответ Tranq слишком велик. Обновите Tranq до последней версии.")
	}
	line = bytes.TrimRight(line, "\r\n")
	if len(line) == 0 {
		// Whether the write failed or not, the door left no answer.
		return nil, errors.New("Tranq закрыл соединение, не ответив. Повторите запрос.")
	}
	return line, nil
}

func parseAnswer(line []byte) (json.RawMessage, error) {
	var answer struct {
		OK       *bool           `json:"ok"`
		Data     json.RawMessage `json:"data"`
		Error    string          `json:"error"`
		Language string          `json:"language"`
	}
	if err := json.Unmarshal(line, &answer); err != nil || answer.OK == nil {
		return nil, errors.New("Tranq ответил непонятно. Обновите Tranq до последней версии и повторите.")
	}
	if !*answer.OK {
		message := answer.Error
		if message == "" {
			message = "Tranq отказал, не объяснив причину."
		}
		return nil, &Refusal{Message: message, Language: answer.Language}
	}
	if len(answer.Data) == 0 {
		return json.RawMessage("null"), nil
	}
	return answer.Data, nil
}
