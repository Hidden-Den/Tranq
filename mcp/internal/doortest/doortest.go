// Package doortest is a fake of the Tranq door for tests: a Unix socket that
// answers canned lines, so no test needs the real app.
package doortest

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// Hangup, returned by a Handler, makes the fake door close the connection
// without answering.
const Hangup = "\x00hangup"

// Handler maps one request line, without its newline, to one answer line,
// also without the newline.
type Handler func(request string) string

// Door is a running fake door.
type Door struct {
	// Path is the socket path to give to the client under test.
	Path string

	mu       sync.Mutex
	requests []string
	accepted int
	conns    map[net.Conn]struct{}
	wg       sync.WaitGroup
}

// ShortDir returns a fresh directory with a path short enough for a Unix
// socket: macOS allows 103 bytes, and t.TempDir() can exceed that.
func ShortDir(t testing.TB) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "tq")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// Serve starts a fake door on a fresh short socket path and answers every
// request line with h.
func Serve(t testing.TB, h Handler) *Door {
	t.Helper()
	return ServeAt(t, filepath.Join(ShortDir(t), "mcp.sock"), h)
}

// ServeAt is Serve on a given path, for tests that bring the door up late.
func ServeAt(t testing.TB, path string, h Handler) *Door {
	t.Helper()
	return start(t, path, func(d *Door, conn net.Conn) {
		reader := bufio.NewReader(conn)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			line = line[:len(line)-1]
			if line == "" {
				continue
			}
			d.record(line)
			answer := h(line)
			if answer == Hangup {
				return
			}
			if _, err := conn.Write([]byte(answer + "\n")); err != nil {
				return
			}
		}
	})
}

// Refuse starts a fake door that behaves as a full one: every connection gets
// line at once, before any request, and is closed.
func Refuse(t testing.TB, line string) *Door {
	t.Helper()
	return start(t, filepath.Join(ShortDir(t), "mcp.sock"), func(_ *Door, conn net.Conn) {
		conn.Write([]byte(line + "\n"))
	})
}

// Requests returns the request lines received so far.
func (d *Door) Requests() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.requests...)
}

// Connections returns how many connections the door has accepted so far,
// whether or not a request came over them. A test uses it to show that a tool
// refused a call without ever reaching the door.
func (d *Door) Connections() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.accepted
}

func (d *Door) record(line string) {
	d.mu.Lock()
	d.requests = append(d.requests, line)
	d.mu.Unlock()
}

func start(t testing.TB, path string, serve func(*Door, net.Conn)) *Door {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	d := &Door{Path: path, conns: map[net.Conn]struct{}{}}
	d.wg.Add(1)
	go func() {
		defer d.wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			d.mu.Lock()
			d.conns[conn] = struct{}{}
			d.accepted++
			d.mu.Unlock()
			d.wg.Add(1)
			go func() {
				defer d.wg.Done()
				serve(d, conn)
				conn.Close()
				d.mu.Lock()
				delete(d.conns, conn)
				d.mu.Unlock()
			}()
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		d.mu.Lock()
		for conn := range d.conns {
			conn.Close()
		}
		d.mu.Unlock()
		d.wg.Wait()
	})
	return d
}
