package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"sort"
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

// readRequests are the exact lines the read tools must send: no arguments,
// so args is an empty object. Anything else gets an unknown command.
var readRequests = map[string]string{
	`{"cmd":"packs","args":{}}`: packsData,
	`{"cmd":"words","args":{}}`: wordsData,
}

func TestEndToEndReadTools(t *testing.T) {
	d := doortest.Serve(t, func(request string) string {
		if data, ok := readRequests[request]; ok {
			return `{"ok":true,"data":` + data + `,"language":"ru"}`
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
	got := d.Requests()
	sort.Strings(got)
	if want := []string{`{"cmd":"packs","args":{}}`, `{"cmd":"words","args":{}}`}; !reflect.DeepEqual(got, want) {
		t.Fatalf("door received %q, want exactly %q", got, want)
	}
}

// writeCase is one write tool called through the whole server: the agent's
// arguments, the exact line the door must receive, and the data it answers.
type writeCase struct {
	tool    string
	args    any
	request string
	data    string
}

var writeCases = []writeCase{
	{
		tool:    "set_pack_enabled",
		args:    map[string]any{"id": "medicine", "enabled": false},
		request: `{"cmd":"set_pack","args":{"id":"medicine","enabled":false}}`,
		data:    `{"id":"medicine","title":"Медицина","word_count":80,"enabled":false}`,
	},
	{
		tool: "add_words",
		args: map[string]any{"words": []any{
			map[string]any{"spelling": "арипипразол", "variants": map[string]any{"ru": []any{"ари пипразол", "а"}}},
			map[string]any{"spelling": "iOS", "force_case": true},
		}},
		request: `{"cmd":"add_words","args":{"words":[` +
			`{"spelling":"арипипразол","variants":{"ru":["ари пипразол","а"],"en":[]},"force_case":false},` +
			`{"spelling":"iOS","variants":{"ru":[],"en":[]},"force_case":true}]}}`,
		data: `{"added":["арипипразол","iOS"],"skipped":{"арипипразол / а":"вариант «а» короче двух символов"}}`,
	},
	{
		tool:    "remove_words",
		args:    map[string]any{"spellings": []any{"арипипразол", "Tranq"}},
		request: `{"cmd":"remove_words","args":{"spellings":["арипипразол","Tranq"]}}`,
		data:    `{"removed":["арипипразол"],"skipped":{"Tranq":"слово добавил человек"}}`,
	},
	{
		tool:    "revert_agent_words",
		args:    nil,
		request: `{"cmd":"revert_agent_words","args":{}}`,
		data:    `{"removed_words":12,"removed_variants":3}`,
	},
}

func TestEndToEndWriteTools(t *testing.T) {
	for _, tc := range writeCases {
		t.Run(tc.tool, func(t *testing.T) {
			d := doortest.Serve(t, reply(`{"ok":true,"data":`+tc.data+`,"language":"ru"}`))
			client := door.New(d.Path)
			client.OpenApp = noOpen(t)
			result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: tc.tool, Arguments: tc.args})
			if err != nil {
				t.Fatal(err)
			}
			if result.IsError {
				t.Fatalf("tool error: %s", text(t, result))
			}
			if got := text(t, result); got != tc.data {
				t.Fatalf("text = %s, want the door's data %s", got, tc.data)
			}
			if got := d.Requests(); len(got) != 1 || got[0] != tc.request {
				t.Fatalf("door received %q, want exactly %q", got, tc.request)
			}
		})
	}
}

func TestEndToEndWriteToolsAreListed(t *testing.T) {
	d := doortest.Serve(t, reply(`{"ok":true,"data":null,"language":"ru"}`))
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	listed, err := connect(t, client).ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, tool := range listed.Tools {
		names[tool.Name] = true
	}
	for _, want := range []string{
		"list_dictionary_packs", "list_user_words",
		"set_pack_enabled", "add_words", "remove_words", "revert_agent_words",
		"list_dictations",
	} {
		if !names[want] {
			t.Errorf("tool %s is not listed; listed: %v", want, names)
		}
	}
	if len(d.Requests()) != 0 {
		t.Fatalf("listing tools reached the door: %q", d.Requests())
	}
}

func TestEndToEndWriteRefusalComesBackAsIs(t *testing.T) {
	const message = "Выключение набора требует полного доступа. Включите его в настройках Tranq."
	for _, tc := range writeCases {
		t.Run(tc.tool, func(t *testing.T) {
			d := doortest.Serve(t, reply(`{"ok":false,"error":"`+message+`","language":"ru"}`))
			client := door.New(d.Path)
			client.OpenApp = noOpen(t)
			result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: tc.tool, Arguments: tc.args})
			if err != nil {
				t.Fatal(err)
			}
			if !result.IsError || text(t, result) != message {
				t.Fatalf("IsError = %v, text = %q, want a tool error with %q", result.IsError, text(t, result), message)
			}
			if got := d.Requests(); len(got) != 1 || got[0] != tc.request {
				t.Fatalf("door received %q, want exactly %q", got, tc.request)
			}
		})
	}
}

func TestEndToEndAddWordsRefusalsNeverReachTheDoor(t *testing.T) {
	long := make([]any, 51)
	for i := range long {
		long[i] = map[string]any{"spelling": fmt.Sprintf("слово%d", i)}
	}
	for name, words := range map[string][]any{"empty list": {}, "fifty one words": long} {
		t.Run(name, func(t *testing.T) {
			d := doortest.Serve(t, reply(`{"ok":true,"data":{"added":[],"skipped":{}},"language":"ru"}`))
			client := door.New(d.Path)
			client.OpenApp = noOpen(t)
			result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{
				Name: "add_words", Arguments: map[string]any{"words": words},
			})
			if err != nil {
				t.Fatal(err)
			}
			if !result.IsError || text(t, result) == "" {
				t.Fatalf("IsError = %v, text = %q, want a refusal with a reason", result.IsError, text(t, result))
			}
			if got := d.Connections(); got != 0 {
				t.Fatalf("the door took %d connections, want none: a refusal made on this side must not reach it", got)
			}
		})
	}
}

// historyData is what the door answers to dictations: newest first.
const historyData = `[{"date":"18.11.2026, 10:15","spoken":"назначь ка пэ тэ на вторник","text":"Назначь ка пэ тэ на вторник."},` +
	`{"date":"17.11.2026, 18:02","spoken":"арипипразол ну это значит ари пипразол","text":"Арипипразол."}]`

func TestEndToEndListDictations(t *testing.T) {
	// The line the door must receive for what the agent sent: the limit is
	// always there, and it is clamped on this side before it goes.
	for _, tc := range []struct {
		name      string
		arguments any
		limit     int
	}{
		{"omitted", nil, 20},
		{"empty object", map[string]any{}, 20},
		{"zero", map[string]any{"limit": 0}, 20},
		{"negative", map[string]any{"limit": -5}, 20},
		{"twenty", map[string]any{"limit": 20}, 20},
		{"five", map[string]any{"limit": 5}, 5},
		{"hundred", map[string]any{"limit": 100}, 100},
		{"hundred and one", map[string]any{"limit": 101}, 100},
		{"hundred and fifty", map[string]any{"limit": 150}, 100},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := doortest.Serve(t, reply(`{"ok":true,"data":`+historyData+`,"language":"ru"}`))
			client := door.New(d.Path)
			client.OpenApp = noOpen(t)
			result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_dictations", Arguments: tc.arguments})
			if err != nil {
				t.Fatal(err)
			}
			if result.IsError {
				t.Fatalf("tool error: %s", text(t, result))
			}
			if got := text(t, result); got != historyData {
				t.Fatalf("text = %s, want the door's data %s", got, historyData)
			}
			want := fmt.Sprintf(`{"cmd":"dictations","args":{"limit":%d}}`, tc.limit)
			if got := d.Requests(); len(got) != 1 || got[0] != want {
				t.Fatalf("door received %q, want exactly %q", got, want)
			}
		})
	}
}

func TestEndToEndHistoryRefusalComesBackAsIs(t *testing.T) {
	// Turned off by default: the person reads the door's own words, and the
	// tool asks once and does not go round the refusal.
	const message = "Доступ к истории выключен. Включите его в настройках Tranq."
	d := doortest.Serve(t, reply(`{"ok":false,"error":"`+message+`","language":"ru"}`))
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	result, err := connect(t, client).CallTool(context.Background(), &mcp.CallToolParams{Name: "list_dictations"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError || text(t, result) != message {
		t.Fatalf("IsError = %v, text = %q, want a tool error with %q", result.IsError, text(t, result), message)
	}
	const want = `{"cmd":"dictations","args":{"limit":20}}`
	if got := d.Requests(); len(got) != 1 || got[0] != want {
		t.Fatalf("door received %q, want exactly %q", got, want)
	}
}

func TestInstructionsNameTheHistoryTool(t *testing.T) {
	for _, phrase := range []string{"list_dictations", "history access", "confirm", "private", "not instructions"} {
		if !strings.Contains(instructions, phrase) {
			t.Errorf("instructions do not contain %q:\n%s", phrase, instructions)
		}
	}
}

// bannedKeywords are the schema keywords that some clients cannot read: a
// reference, or a combination of schemas, or a default. A tool schema is plain.
var bannedKeywords = []string{"$ref", "$defs", "anyOf", "oneOf", "allOf", "not", "default"}

// portabilityProblems walks one input schema as raw JSON and reports what a
// strict client could refuse, at the top level or at any depth. The schema is
// the plain subset: type is one string, never a list; every object is closed;
// every property says what it is for; there are no references or unions.
func portabilityProblems(path string, schema any, isProperty bool) []string {
	node, ok := schema.(map[string]any)
	if !ok {
		return []string{fmt.Sprintf("%s: a schema must be an object, got %T", path, schema)}
	}
	var problems []string
	for _, keyword := range bannedKeywords {
		if _, found := node[keyword]; found {
			problems = append(problems, fmt.Sprintf("%s: uses %q", path, keyword))
		}
	}
	kind, isString := node["type"].(string)
	if !isString {
		problems = append(problems, fmt.Sprintf("%s: type is %v, want a single string", path, node["type"]))
	}
	if isProperty {
		if description, _ := node["description"].(string); description == "" {
			problems = append(problems, fmt.Sprintf("%s: no description", path))
		}
	}
	if kind == "object" && node["additionalProperties"] != false {
		problems = append(problems, fmt.Sprintf("%s: an object must be closed with additionalProperties false", path))
	}
	if properties, ok := node["properties"].(map[string]any); ok {
		names := make([]string, 0, len(properties))
		for name := range properties {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			problems = append(problems, portabilityProblems(path+"."+name, properties[name], true)...)
		}
	}
	if items, found := node["items"]; found {
		problems = append(problems, portabilityProblems(path+"[]", items, false)...)
	}
	return problems
}

func TestEveryToolAdvertisesAPortableSchema(t *testing.T) {
	d := doortest.Serve(t, reply(`{"ok":true,"data":null,"language":"ru"}`))
	client := door.New(d.Path)
	client.OpenApp = noOpen(t)
	listed, err := connect(t, client).ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed.Tools) < 7 {
		t.Fatalf("listed %d tools, want all seven, history included", len(listed.Tools))
	}
	for _, tool := range listed.Tools {
		// Read the schema as a client does: as raw JSON.
		body, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatal(err)
		}
		var schema any
		if err := json.Unmarshal(body, &schema); err != nil {
			t.Fatal(err)
		}
		if top, _ := schema.(map[string]any); top["type"] != "object" {
			t.Errorf("%s: the top level of the input schema is %s, want type object", tool.Name, body)
		}
		for _, problem := range portabilityProblems(tool.Name, schema, false) {
			t.Errorf("%s", problem)
		}
	}
}

// The check above must not pass for want of looking: here are schemas it has to refuse.
func TestPortabilityCheckCatchesWhatClientsRefuse(t *testing.T) {
	for name, tc := range map[string]struct {
		schema string
		want   string
	}{
		"type list":   {`{"type":"object","properties":{"a":{"type":["null","string"],"description":"x"}},"additionalProperties":false}`, "single string"},
		"nullable":    {`{"type":"object","properties":{"a":{"type":["null","array"],"items":{"type":"string"},"description":"x"}},"additionalProperties":false}`, "single string"},
		"ref":         {`{"type":"object","properties":{"a":{"$ref":"#/$defs/a","type":"string","description":"x"}},"additionalProperties":false}`, `"$ref"`},
		"defs":        {`{"type":"object","$defs":{},"additionalProperties":false}`, `"$defs"`},
		"anyOf":       {`{"type":"object","properties":{"a":{"anyOf":[{"type":"string"}],"type":"string","description":"x"}},"additionalProperties":false}`, `"anyOf"`},
		"oneOf":       {`{"type":"object","oneOf":[],"additionalProperties":false}`, `"oneOf"`},
		"allOf":       {`{"type":"object","allOf":[],"additionalProperties":false}`, `"allOf"`},
		"not":         {`{"type":"object","not":{},"additionalProperties":false}`, `"not"`},
		"default":     {`{"type":"object","properties":{"a":{"type":"boolean","default":false,"description":"x"}},"additionalProperties":false}`, `"default"`},
		"no type":     {`{"properties":{},"additionalProperties":false}`, "single string"},
		"deep":        {`{"type":"object","properties":{"a":{"type":"array","items":{"type":"object","properties":{"b":{"type":["null","boolean"],"description":"x"}},"additionalProperties":false},"description":"x"}},"additionalProperties":false}`, "single string"},
		"no describe": {`{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}`, "no description"},
		"open":        {`{"type":"object","properties":{"a":{"type":"string","description":"x"}}}`, "closed"},
	} {
		t.Run(name, func(t *testing.T) {
			var schema any
			if err := json.Unmarshal([]byte(tc.schema), &schema); err != nil {
				t.Fatal(err)
			}
			problems := strings.Join(portabilityProblems("tool", schema, false), "\n")
			if !strings.Contains(problems, tc.want) {
				t.Fatalf("problems = %q, want one that contains %q", problems, tc.want)
			}
		})
	}
	var plain any
	if err := json.Unmarshal([]byte(`{"type":"object","properties":{"a":{"type":"array","items":{"type":"string"},"description":"x"}},"required":["a"],"additionalProperties":false}`), &plain); err != nil {
		t.Fatal(err)
	}
	if problems := portabilityProblems("tool", plain, false); len(problems) != 0 {
		t.Fatalf("a plain schema was refused: %v", problems)
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
