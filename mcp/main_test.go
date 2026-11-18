package main

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Nuteres/Tranq/mcp/door"
	"github.com/Nuteres/Tranq/mcp/internal/doortest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	packsData = `[{"id":"it","title":"IT","word_count":120,"enabled":true},{"id":"medicine","title":"Медицина","word_count":80,"enabled":false}]`
	wordsData = `[{"spelling":"Kubernetes","variants":{"ru":["кубер"],"en":[]},"source":"manual","hits":3,"last_used":"2026-11-17T10:00:00Z"},{"spelling":"Tranq","variants":{"ru":[],"en":[]},"source":"mcp","hits":0,"last_used":null}]`
)

// connect runs the real server against a door client over the SDK's
// in-memory transport and returns the agent side.
func connect(t *testing.T, client *door.Client) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	serverSession, err := newServer(client).Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { serverSession.Close() })
	session, err := mcp.NewClient(&mcp.Implementation{Name: "agent", Version: "0"}, nil).Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

func noOpen(t *testing.T) func(context.Context, ...string) error {
	return func(context.Context, ...string) error {
		t.Error("a test must never open a real app")
		return errors.New("not in tests")
	}
}

func reply(line string) doortest.Handler { return func(string) string { return line } }

func text(t *testing.T, result *mcp.CallToolResult) string {
	t.Helper()
	if len(result.Content) != 1 {
		t.Fatalf("want one content item, got %d", len(result.Content))
	}
	content, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("want text content, got %T", result.Content[0])
	}
	return content.Text
}

func TestEndToEndReadTools(t *testing.T) {
	d := doortest.Serve(t, func(request string) string {
		switch {
		case strings.Contains(request, `"cmd":"packs"`):
			return `{"ok":true,"data":` + packsData + `,"language":"ru"}`
		case strings.Contains(request, `"cmd":"words"`):
			return `{"ok":true,"data":` + wordsData + `,"language":"ru"}`
		}
		return `{"ok":false,"error":"Неизвестная команда.","language":"ru"}`
	})
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	session := connect(t, client)
	ctx := context.Background()

	listed, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, tool := range listed.Tools {
		names[tool.Name] = true
	}
	for _, want := range []string{"list_dictionary_packs", "list_user_words"} {
		if !names[want] {
			t.Errorf("tool %s is not listed; listed: %v", want, names)
		}
	}

	for name, want := range map[string]string{
		"list_dictionary_packs": packsData,
		"list_user_words":       wordsData,
	} {
		result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: name})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if result.IsError {
			t.Fatalf("%s: tool error: %s", name, text(t, result))
		}
		if got := text(t, result); got != want {
			t.Fatalf("%s: text = %s, want %s", name, got, want)
		}
	}
	if got := len(d.Requests()); got != 2 {
		t.Fatalf("door got %d requests, want 2: %q", got, d.Requests())
	}
}

func TestEndToEndDoorRefusal(t *testing.T) {
	const message = "Доступ нейронок выключен. Включите его в настройках Tranq."
	d := doortest.Serve(t, reply(`{"ok":false,"error":"`+message+`","language":"ru"}`))
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_user_words"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError || text(t, result) != message {
		t.Fatalf("IsError = %v, text = %q, want a tool error with %q", result.IsError, text(t, result), message)
	}
}

func TestEndToEndConnectTimeRefusal(t *testing.T) {
	const message = "Слишком много соединений. Закройте лишние и повторите."
	d := doortest.Refuse(t, `{"ok":false,"error":"`+message+`","language":"ru"}`)
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	session := connect(t, client)
	for i := 0; i < 20; i++ {
		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "list_dictionary_packs"})
		if err != nil {
			t.Fatal(err)
		}
		if !result.IsError || text(t, result) != message {
			t.Fatalf("attempt %d: IsError = %v, text = %q, want a tool error with %q", i, result.IsError, text(t, result), message)
		}
	}
}

func TestEndToEndGarbageLine(t *testing.T) {
	d := doortest.Serve(t, reply("<html>not the door</html>"))
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_dictionary_packs"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError || !strings.Contains(text(t, result), "Tranq") {
		t.Fatalf("IsError = %v, text = %q, want an understandable tool error", result.IsError, text(t, result))
	}
}

func TestEndToEndAppClosed(t *testing.T) {
	client := door.New(filepath.Join(doortest.ShortDir(t), "mcp.sock"))
	opened := 0
	// The app does not come: the opener fails, so there is no five second wait.
	client.OpenApp = func(context.Context, ...string) error {
		opened++
		return errors.New("no such app")
	}
	result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_dictionary_packs"})
	if err != nil {
		t.Fatal(err)
	}
	const want = "Откройте Tranq и включите доступ для нейронок в настройках"
	if !result.IsError || text(t, result) != want {
		t.Fatalf("IsError = %v, text = %q, want a tool error with %q", result.IsError, text(t, result), want)
	}
	if opened != 1 {
		t.Fatalf("the app was opened %d times, want 1", opened)
	}
}

func TestVersionFlagPrintsVersionToStdoutOnly(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--version"}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, stderr.String())
	}
	if got := strings.TrimSpace(stdout.String()); !strings.HasPrefix(got, "tranq-mcp ") || len(got) <= len("tranq-mcp ") {
		t.Fatalf("stdout = %q, want a version line", stdout.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestUnknownFlagIsUsageErrorOnStderr(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--nope"}, &stdout, &stderr); code != 2 {
		t.Fatalf("exit code %d, want 2", code)
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q: stdout belongs to the protocol, nothing else may be written there", stdout.String())
	}
	if stderr.Len() == 0 {
		t.Fatal("want a usage message on stderr")
	}
}
