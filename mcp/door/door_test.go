package door

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Nuteres/Tranq/mcp/internal/doortest"
)

const humanUnavailable = "Откройте Tranq и включите доступ для нейронок в настройках"

func newClient(t *testing.T, path string) *Client {
	t.Helper()
	c := New(path)
	c.OpenApp = func(context.Context, ...string) error {
		t.Error("a test must never open a real app")
		return nil
	}
	return c
}

func TestCallReturnsData(t *testing.T) {
	d := doortest.Serve(t, func(string) string {
		return `{"ok":true,"data":[{"id":"it","title":"IT","word_count":3,"enabled":true}],"language":"ru"}`
	})
	data, err := newClient(t, d.Path).Call(context.Background(), "packs", nil)
	if err != nil {
		t.Fatal(err)
	}
	if want := `[{"id":"it","title":"IT","word_count":3,"enabled":true}]`; string(data) != want {
		t.Fatalf("data = %s, want %s", data, want)
	}
	if got, want := d.Requests(), []string{`{"cmd":"packs","args":{}}`}; !reflect.DeepEqual(got, want) {
		t.Fatalf("requests = %q, want %q", got, want)
	}
}

func TestCallSendsArgs(t *testing.T) {
	d := doortest.Serve(t, func(string) string { return `{"ok":true,"data":{},"language":"en"}` })
	args := map[string]any{"id": "it", "enabled": false}
	if _, err := newClient(t, d.Path).Call(context.Background(), "set_pack", args); err != nil {
		t.Fatal(err)
	}
	got := d.Requests()
	if len(got) != 1 {
		t.Fatalf("requests = %q", got)
	}
	var request struct {
		Cmd  string         `json:"cmd"`
		Args map[string]any `json:"args"`
	}
	if err := json.Unmarshal([]byte(got[0]), &request); err != nil {
		t.Fatal(err)
	}
	if request.Cmd != "set_pack" || !reflect.DeepEqual(request.Args, args) {
		t.Fatalf("request = %+v", request)
	}
}

func TestCallReturnsDoorError(t *testing.T) {
	const text = "Для этого нужен полный доступ. Включите его в настройках Tranq."
	d := doortest.Serve(t, func(string) string {
		return `{"ok":false,"error":"` + text + `","language":"ru"}`
	})
	data, err := newClient(t, d.Path).Call(context.Background(), "remove_words", map[string]any{"spellings": []string{"x"}})
	if err == nil {
		t.Fatalf("want an error, got data %s", data)
	}
	if err.Error() != text {
		t.Fatalf("error text = %q, want %q", err.Error(), text)
	}
	var refusal *Refusal
	if !errors.As(err, &refusal) || refusal.Language != "ru" {
		t.Fatalf("want a *Refusal with language ru, got %#v", err)
	}
	if errors.Is(err, ErrUnavailable) {
		t.Fatal("a refusal of the door is not an unavailable door")
	}
}

func TestCallSurvivesGarbageLine(t *testing.T) {
	for name, line := range map[string]string{
		"not json":          "this is not json at all",
		"truncated":         `{"ok":true,"data":[`,
		"json array":        `[1,2,3]`,
		"json string":       `"hello"`,
		"object without ok": `{"data":[],"language":"ru"}`,
		"ok of wrong type":  `{"ok":"yes","data":[]}`,
		"binary":            "\x00\x01\x02\xff",
	} {
		t.Run(name, func(t *testing.T) {
			d := doortest.Serve(t, func(string) string { return line })
			data, err := newClient(t, d.Path).Call(context.Background(), "packs", nil)
			if err == nil {
				t.Fatalf("want an error, got data %s", data)
			}
			if !strings.Contains(err.Error(), "Tranq") {
				t.Fatalf("error text %q does not say what is wrong", err.Error())
			}
		})
	}
}

func TestCallSurvivesEmptyRefusalText(t *testing.T) {
	d := doortest.Serve(t, func(string) string { return `{"ok":false,"language":"ru"}` })
	_, err := newClient(t, d.Path).Call(context.Background(), "packs", nil)
	if err == nil || err.Error() == "" {
		t.Fatalf("want an error with some text, got %v", err)
	}
}

func TestCallSurvivesHangup(t *testing.T) {
	d := doortest.Serve(t, func(string) string { return doortest.Hangup })
	_, err := newClient(t, d.Path).Call(context.Background(), "packs", nil)
	if err == nil || !strings.Contains(err.Error(), "Tranq") {
		t.Fatalf("want an understandable error, got %v", err)
	}
}

func TestCallReadsConnectTimeRefusal(t *testing.T) {
	const text = "Слишком много соединений. Закройте лишние и повторите."
	d := doortest.Refuse(t, `{"ok":false,"error":"`+text+`","language":"ru"}`)
	// The refusal races with the request: the door may have closed the
	// connection before the client writes. Repeat to catch both orders.
	for i := 0; i < 300; i++ {
		_, err := newClient(t, d.Path).Call(context.Background(), "packs", nil)
		if err == nil || err.Error() != text {
			t.Fatalf("attempt %d: error = %v, want %q", i, err, text)
		}
	}
}

func TestCallReadsAnswerLargerThanBuffer(t *testing.T) {
	big := strings.Repeat("слово ", 100_000)
	d := doortest.Serve(t, func(string) string {
		return `{"ok":true,"data":"` + big + `","language":"ru"}`
	})
	data, err := newClient(t, d.Path).Call(context.Background(), "words", nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != len(big)+2 {
		t.Fatalf("got %d bytes, want %d", len(data), len(big)+2)
	}
}

func TestCallHonoursContext(t *testing.T) {
	release := make(chan struct{})
	d := doortest.Serve(t, func(string) string {
		<-release
		return doortest.Hangup
	})
	defer close(release)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := newClient(t, d.Path).Call(ctx, "packs", nil)
	if err == nil {
		t.Fatal("want an error")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v, want the context deadline", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("Call ignored the context for %v", time.Since(start))
	}
}

func TestCallTimesOutOnSilentDoor(t *testing.T) {
	release := make(chan struct{})
	d := doortest.Serve(t, func(string) string {
		<-release
		return doortest.Hangup
	})
	defer close(release)
	c := newClient(t, d.Path)
	c.Timeout = 100 * time.Millisecond
	_, err := c.Call(context.Background(), "packs", nil)
	if err == nil || !strings.Contains(err.Error(), "Tranq") {
		t.Fatalf("want an understandable timeout error, got %v", err)
	}
}

func TestCallRunsInParallel(t *testing.T) {
	d := doortest.Serve(t, func(string) string { return `{"ok":true,"data":1,"language":"ru"}` })
	c := newClient(t, d.Path)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := c.Call(context.Background(), "packs", nil); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
}

func TestMissingSocketGivesHumanError(t *testing.T) {
	c := newClient(t, filepath.Join(doortest.ShortDir(t), "mcp.sock"))
	_, err := c.Call(context.Background(), "packs", nil)
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("error = %v, want ErrUnavailable", err)
	}
	if err.Error() != humanUnavailable {
		t.Fatalf("error text = %q, want %q", err.Error(), humanUnavailable)
	}
}

func TestStaleSocketFileGivesHumanError(t *testing.T) {
	// The app crashed and left the file behind: connecting is refused rather than "no such file".
	path := filepath.Join(doortest.ShortDir(t), "mcp.sock")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := newClient(t, path).Call(context.Background(), "packs", nil)
	if !errors.Is(err, ErrUnavailable) || err.Error() != humanUnavailable {
		t.Fatalf("error = %v, want the human text", err)
	}
}

func TestEnsureAppDoesNotOpenWhenSocketIsAlive(t *testing.T) {
	d := doortest.Serve(t, func(string) string { return `{"ok":true,"data":[],"language":"ru"}` })
	if err := newClient(t, d.Path).EnsureApp(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureAppOpensAppAndWaitsForSocket(t *testing.T) {
	path := filepath.Join(doortest.ShortDir(t), "mcp.sock")
	c := New(path)
	c.executable = func() (string, error) { return "/Applications/Tranq.app/Contents/MacOS/tranq-mcp", nil }
	var opened [][]string
	c.OpenApp = func(_ context.Context, args ...string) error {
		opened = append(opened, args)
		// The app needs a moment to come up and start listening.
		time.AfterFunc(300*time.Millisecond, func() {
			doortest.ServeAt(t, path, func(string) string { return `{"ok":true,"data":[],"language":"ru"}` })
		})
		return nil
	}
	start := time.Now()
	if err := c.EnsureApp(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := time.Since(start); got < 250*time.Millisecond || got > 3*time.Second {
		t.Fatalf("waited %v, want about 300ms", got)
	}
	if want := [][]string{{"/Applications/Tranq.app"}}; !reflect.DeepEqual(opened, want) {
		t.Fatalf("open called with %q, want %q", opened, want)
	}
}

func TestEnsureAppGivesUpWithHumanError(t *testing.T) {
	c := New(filepath.Join(doortest.ShortDir(t), "mcp.sock"))
	c.executable = func() (string, error) { return "/Applications/Tranq.app/Contents/MacOS/tranq-mcp", nil }
	c.OpenApp = func(context.Context, ...string) error { return nil }
	c.waitFor = 300 * time.Millisecond
	start := time.Now()
	err := c.EnsureApp(context.Background())
	if !errors.Is(err, ErrUnavailable) || err.Error() != humanUnavailable {
		t.Fatalf("error = %v, want the human text", err)
	}
	if got := time.Since(start); got < 250*time.Millisecond || got > 3*time.Second {
		t.Fatalf("waited %v, want about 300ms", got)
	}
}

func TestEnsureAppDefaultWaitIsFiveSeconds(t *testing.T) {
	c := New("unused")
	if c.waitFor != 5*time.Second || c.pollEvery != 100*time.Millisecond {
		t.Fatalf("wait %v every %v, want 5s every 100ms", c.waitFor, c.pollEvery)
	}
}

func TestEnsureAppFailsFastWhenOpenFails(t *testing.T) {
	c := New(filepath.Join(doortest.ShortDir(t), "mcp.sock"))
	c.executable = func() (string, error) { return "/usr/local/bin/tranq-mcp", nil }
	c.OpenApp = func(context.Context, ...string) error { return errors.New("no application knows bundle id") }
	start := time.Now()
	err := c.EnsureApp(context.Background())
	if !errors.Is(err, ErrUnavailable) || err.Error() != humanUnavailable {
		t.Fatalf("error = %v, want the human text", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("EnsureApp waited although the app could not be opened")
	}
}

func TestEnsureAppStopsOnContext(t *testing.T) {
	c := New(filepath.Join(doortest.ShortDir(t), "mcp.sock"))
	c.executable = func() (string, error) { return "/Applications/Tranq.app/Contents/MacOS/tranq-mcp", nil }
	c.OpenApp = func(context.Context, ...string) error { return nil }
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := c.EnsureApp(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v, want the context deadline", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("EnsureApp ignored the context")
	}
}

func TestOpenArgs(t *testing.T) {
	for name, tc := range map[string]struct {
		exe  string
		want []string
	}{
		"installed bundle":       {"/Applications/Tranq.app/Contents/MacOS/tranq-mcp", []string{"/Applications/Tranq.app"}},
		"bundle with a space":    {"/Users/a b/My Apps/Tranq.app/Contents/MacOS/tranq-mcp", []string{"/Users/a b/My Apps/Tranq.app"}},
		"development binary":     {"/Users/nuter/go/bin/tranq-mcp", []string{"-b", "nuter.Tranq"}},
		"app folder, wrong spot": {"/Applications/Tranq.app/tranq-mcp", []string{"-b", "nuter.Tranq"}},
		"resources, not MacOS":   {"/Applications/Tranq.app/Contents/Resources/tranq-mcp", []string{"-b", "nuter.Tranq"}},
		"another app":            {"/Applications/Other.app/Contents/MacOS/tranq-mcp", []string{"/Applications/Other.app"}},
	} {
		t.Run(name, func(t *testing.T) {
			if got := openArgs(tc.exe); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("openArgs(%q) = %q, want %q", tc.exe, got, tc.want)
			}
		})
	}
}

func TestOpenArgsResolvesSymlinkedBinary(t *testing.T) {
	// An agent may be configured with a symlink to the binary inside the bundle.
	root, err := filepath.EvalSymlinks(doortest.ShortDir(t))
	if err != nil {
		t.Fatal(err)
	}
	macOS := filepath.Join(root, "Tranq.app", "Contents", "MacOS")
	if err := os.MkdirAll(macOS, 0o755); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(macOS, "tranq-mcp")
	if err := os.WriteFile(binary, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "tranq-mcp")
	if err := os.Symlink(binary, link); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(link)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{filepath.Join(root, "Tranq.app")}; !reflect.DeepEqual(openArgs(resolved), want) {
		t.Fatalf("openArgs = %q, want %q", openArgs(resolved), want)
	}
}

func TestSocketPath(t *testing.T) {
	t.Run("default", func(t *testing.T) {
		t.Setenv("TRANQ_MCP_SOCKET", "")
		config, err := os.UserConfigDir()
		if err != nil {
			t.Skip(err)
		}
		if got, want := SocketPath(), filepath.Join(config, "Tranq", "mcp.sock"); got != want {
			t.Fatalf("SocketPath() = %q, want %q", got, want)
		}
	})
	t.Run("environment override", func(t *testing.T) {
		t.Setenv("TRANQ_MCP_SOCKET", "/tmp/dev.sock")
		if got := SocketPath(); got != "/tmp/dev.sock" {
			t.Fatalf("SocketPath() = %q", got)
		}
	})
}
