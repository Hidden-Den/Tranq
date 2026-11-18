package tools_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"unicode"

	"github.com/Nuteres/Tranq/mcp/door"
	"github.com/Nuteres/Tranq/mcp/tools"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// fakeDoor is a tools.Door that answers canned data per command.
type fakeDoor struct {
	mu        sync.Mutex
	calls     []string
	args      []any
	data      map[string]string
	err       error
	downFor   int   // the first downFor calls fail with door.ErrUnavailable
	ensureErr error // what EnsureApp returns
	ensured   int
}

func (f *fakeDoor) Call(_ context.Context, cmd string, args any) (json.RawMessage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, cmd)
	f.args = append(f.args, args)
	if f.downFor > 0 {
		f.downFor--
		return nil, door.ErrUnavailable
	}
	if f.err != nil {
		return nil, f.err
	}
	return json.RawMessage(f.data[cmd]), nil
}

func (f *fakeDoor) EnsureApp(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ensured++
	if f.ensureErr == nil {
		f.downFor = 0
	}
	return f.ensureErr
}

func connect(t *testing.T, d tools.Door) *mcp.ClientSession {
	t.Helper()
	server := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	tools.Register(server, d)
	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { serverSession.Close() })
	session, err := mcp.NewClient(&mcp.Implementation{Name: "client", Version: "0"}, nil).Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

func listTools(t *testing.T, session *mcp.ClientSession) map[string]*mcp.Tool {
	t.Helper()
	result, err := session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]*mcp.Tool{}
	for _, tool := range result.Tools {
		byName[tool.Name] = tool
	}
	return byName
}

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

func TestReadToolsDescribeEveryField(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	// Every field of the door's answer, spelled as the agent will see it.
	required := map[string][]string{
		"list_dictionary_packs": {"`id`", "`title`", "`word_count`", "`enabled`"},
		"list_user_words": {
			"`spelling`", "`variants`", "`ru`", "`en`", "`source`", "`manual`", "`learned`", "`mcp`",
			"`hits`", "`last_used`", "ISO 8601", "null",
		},
	}
	for name, fields := range required {
		tool, ok := byName[name]
		if !ok {
			t.Errorf("tool %s is not registered", name)
			continue
		}
		if len(tool.Description) < 400 {
			t.Errorf("%s: description is %d bytes, an agent chooses tools by it, so it must be detailed", name, len(tool.Description))
		}
		for _, r := range tool.Description {
			if unicode.Is(unicode.Cyrillic, r) {
				t.Errorf("%s: description must be in English, found %q", name, r)
				break
			}
		}
		for _, field := range fields {
			if !strings.Contains(tool.Description, field) {
				t.Errorf("%s: description does not explain %s", name, field)
			}
		}
		if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
			t.Errorf("%s: must be marked read-only", name)
		}
	}
}

func TestReadToolDescriptionsDoNotPromisePackContents(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	packs, words := byName["list_dictionary_packs"], byName["list_user_words"]
	if packs == nil || words == nil {
		t.Fatalf("read tools are not registered: %v", byName)
	}
	// list_dictionary_packs returns id, title, word_count and enabled, never the words of a pack.
	if !strings.Contains(packs.Description, "not exposed by this server") {
		t.Errorf("list_dictionary_packs must say that pack contents are not exposed:\n%s", packs.Description)
	}
	if !strings.Contains(words.Description, "not exposed by this server") {
		t.Errorf("list_user_words must say that pack contents are not exposed:\n%s", words.Description)
	}
	if strings.Contains(words.Description, "for those use list_dictionary_packs") {
		t.Errorf("list_user_words sends the agent to list_dictionary_packs for pack words, which it does not have:\n%s", words.Description)
	}
	// The way back from a bad batch is named where the agent learns what `mcp` means.
	if !strings.Contains(words.Description, "revert_agent_words") {
		t.Errorf("list_user_words must name revert_agent_words:\n%s", words.Description)
	}
}

func TestReadToolsReturnDoorData(t *testing.T) {
	packs := `[{"id":"it","title":"IT","word_count":120,"enabled":true}]`
	words := `[{"spelling":"Kubernetes","variants":{"ru":["кубер"],"en":[]},"source":"manual","hits":3,"last_used":null}]`
	for name, tc := range map[string]struct{ cmd, data string }{
		"list_dictionary_packs": {"packs", packs},
		"list_user_words":       {"words", words},
	} {
		t.Run(name, func(t *testing.T) {
			d := &fakeDoor{data: map[string]string{"packs": packs, "words": words}}
			session := connect(t, d)
			// An agent may send no arguments at all, or an empty object.
			for _, arguments := range []any{nil, map[string]any{}} {
				result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: arguments})
				if err != nil {
					t.Fatal(err)
				}
				if result.IsError {
					t.Fatalf("unexpected tool error: %s", text(t, result))
				}
				if got := text(t, result); got != tc.data {
					t.Fatalf("text = %s, want %s", got, tc.data)
				}
			}
			if got := d.calls; len(got) != 2 || got[0] != tc.cmd || got[1] != tc.cmd {
				t.Fatalf("door was asked %q, want %q twice", got, tc.cmd)
			}
		})
	}
}

func TestToolErrorCarriesDoorTextAsIs(t *testing.T) {
	const message = "Доступ нейронок выключен. Включите его в настройках Tranq."
	d := &fakeDoor{err: &door.Refusal{Message: message, Language: "ru"}}
	session := connect(t, d)
	for _, name := range []string{"list_dictionary_packs", "list_user_words"} {
		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: name})
		if err != nil {
			t.Fatalf("%s: a refusal of the door is a tool error, not a protocol error: %v", name, err)
		}
		if !result.IsError {
			t.Fatalf("%s: want IsError", name)
		}
		if got := text(t, result); got != message {
			t.Fatalf("%s: text = %q, want %q", name, got, message)
		}
	}
}

func TestToolStartsTheAppWhenDoorIsDown(t *testing.T) {
	d := &fakeDoor{downFor: 1, data: map[string]string{"packs": `[]`}}
	result, err := connect(t, d).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_dictionary_packs"})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError {
		t.Fatalf("unexpected tool error: %s", text(t, result))
	}
	if d.ensured != 1 || len(d.calls) != 2 {
		t.Fatalf("EnsureApp called %d times and the door %d times, want 1 and 2", d.ensured, len(d.calls))
	}
}

func TestToolReportsAppThatDoesNotCome(t *testing.T) {
	d := &fakeDoor{downFor: 99, ensureErr: door.ErrUnavailable}
	result, err := connect(t, d).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_user_words"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError {
		t.Fatal("want IsError")
	}
	if got, want := text(t, result), "Откройте Tranq и включите доступ для нейронок в настройках"; got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
	if d.ensured != 1 {
		t.Fatalf("EnsureApp called %d times, want 1: the app must be asked to start before giving up", d.ensured)
	}
	if len(d.calls) != 1 {
		t.Fatalf("the door was asked %d times, want 1: no retry when the app did not come", len(d.calls))
	}
}

func TestToolDoesNotStartTheAppForOtherErrors(t *testing.T) {
	d := &fakeDoor{err: errors.New("Tranq ответил непонятно")}
	result, err := connect(t, d).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_user_words"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError || d.ensured != 0 {
		t.Fatalf("IsError = %v, EnsureApp calls = %d, want a tool error and no launch", result.IsError, d.ensured)
	}
}
