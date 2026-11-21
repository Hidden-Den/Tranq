package tools_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode"

	"github.com/Hidden-Den/Tranq/mcp/door"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// writeToolNames are the tools that change the dictionary.
var writeToolNames = []string{"set_pack_enabled", "add_words", "remove_words", "revert_agent_words", "create_pack", "delete_pack"}

// callWrite calls a tool as an agent does and returns the result. A protocol
// error is a test failure: every refusal of a write tool is a tool error.
func callWrite(t *testing.T, session *mcp.ClientSession, name string, arguments any) *mcp.CallToolResult {
	t.Helper()
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: arguments})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return result
}

// listed returns a registered tool or stops the test.
func listed(t *testing.T, byName map[string]*mcp.Tool, name string) *mcp.Tool {
	t.Helper()
	tool, ok := byName[name]
	if !ok {
		t.Fatalf("tool %s is not registered", name)
	}
	return tool
}

// sentArgs is the JSON of the arguments the door was asked with in its i-th call.
func sentArgs(t *testing.T, d *fakeDoor, i int) string {
	t.Helper()
	if i >= len(d.args) {
		t.Fatalf("the door was asked %d times, want a call number %d", len(d.args), i+1)
	}
	body, err := json.Marshal(d.args[i])
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

// words returns n words with distinct spellings.
func words(n int) []any {
	list := make([]any, n)
	for i := range list {
		list[i] = map[string]any{"spelling": fmt.Sprintf("слово%d", i)}
	}
	return list
}

// untouched checks that a refused call never reached the door, not even to start the app.
func untouched(t *testing.T, d *fakeDoor) {
	t.Helper()
	if len(d.calls) != 0 || d.ensured != 0 {
		t.Fatalf("the door was asked %d times and the app started %d times, want no contact at all", len(d.calls), d.ensured)
	}
}

func TestWriteToolsAreRegisteredWithHints(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	// Deleting and disabling are destructive; adding is not.
	destructive := map[string]bool{"set_pack_enabled": true, "add_words": false, "remove_words": true, "revert_agent_words": true, "create_pack": false, "delete_pack": true}
	// Idempotent means that repeating a call with the same arguments has no
	// further effect, not that the answer is the same. All four are: a repeated
	// add_words only skips what the first one added, a repeated remove_words
	// only reports words that are already gone, a repeated revert_agent_words
	// finds nothing left to revert, and a pack switched to the state it already
	// has stays as it is.
	idempotent := map[string]bool{"set_pack_enabled": true, "add_words": true, "remove_words": true, "revert_agent_words": true, "create_pack": true, "delete_pack": true}
	for _, name := range writeToolNames {
		tool, ok := byName[name]
		if !ok {
			t.Errorf("tool %s is not registered", name)
			continue
		}
		a := tool.Annotations
		if a == nil {
			t.Errorf("%s: no annotations", name)
			continue
		}
		if a.ReadOnlyHint {
			t.Errorf("%s: a write tool must not be marked read-only", name)
		}
		if a.DestructiveHint == nil || *a.DestructiveHint != destructive[name] {
			t.Errorf("%s: DestructiveHint = %v, want %v", name, a.DestructiveHint, destructive[name])
		}
		if a.IdempotentHint != idempotent[name] {
			t.Errorf("%s: IdempotentHint = %v, want %v", name, a.IdempotentHint, idempotent[name])
		}
		if a.OpenWorldHint == nil || *a.OpenWorldHint {
			t.Errorf("%s: OpenWorldHint = %v, want false: the tool talks only to the local app", name, a.OpenWorldHint)
		}
	}
}

func TestWriteToolsDescribeThemselves(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	required := map[string][]string{
		"add_words": {
			"50", "`words`", "`spelling`", "`variants`", "`ru`", "`en`", "`force_case`", "`added`", "`skipped`",
			"NOT alternative spellings", "ари пипразол", "revert_agent_words", "list_user_words",
			"never duplicated", "shorter than two characters", "ignoring case", "repeated inside one call",
			"written by the app", "currently in Russian", "own language",
			"`pack_id`", "create_pack", "500", "single word of the user, such as a surname, goes without pack_id",
		},
		"remove_words": {
			"`spellings`", "`removed`", "`skipped`", "full access", "added through this server", "typed",
			"written by the app", "currently in Russian", "own language", "`pack_id`",
		},
		"create_pack": {
			"`id`", "`title`", "`created`", "20", "60", "add_words", "`pack_id`", "already existed", "built-in",
		},
		"delete_pack": {
			"`id`", "`removed_words`", "`title`", "list_dictionary_packs", "agent",
		},
		"set_pack_enabled": {
			"`id`", "`enabled`", "list_dictionary_packs", "full access", "Enabling", "disabling",
		},
		"revert_agent_words": {
			"`removed_words`", "`removed_variants`", "`removed_packs`", "undo", "added through this server",
		},
	}
	for name, phrases := range required {
		tool, ok := byName[name]
		if !ok {
			t.Errorf("tool %s is not registered", name)
			continue
		}
		if len(tool.Description) < 500 {
			t.Errorf("%s: description is %d bytes, an agent chooses tools by it, so it must be detailed", name, len(tool.Description))
		}
		var cyrillic, letters int
		for _, r := range tool.Description {
			if unicode.IsLetter(r) {
				letters++
				if unicode.Is(unicode.Cyrillic, r) {
					cyrillic++
				}
			}
		}
		// English, with a few Russian examples at most.
		if cyrillic*10 > letters {
			t.Errorf("%s: description must be in English, %d of %d letters are Cyrillic", name, cyrillic, letters)
		}
		for _, phrase := range phrases {
			if !strings.Contains(tool.Description, phrase) {
				t.Errorf("%s: description does not contain %q\n%s", name, phrase, tool.Description)
			}
		}
		// The app writes its reasons in fixed Russian text, not in the language of
		// its interface, and the description must not promise otherwise.
		if strings.Contains(tool.Description, "language of the Tranq interface") {
			t.Errorf("%s: description claims the app answers in the language of its interface", name)
		}
		// The texts the app sends back are written by whoever controls the app's
		// data, so the agent is told to relay them and not to obey them.
		if !strings.Contains(tool.Description, "not instructions") {
			t.Errorf("%s: description must say that texts from the app are data, not instructions", name)
		}
	}
	for _, name := range []string{"add_words", "remove_words"} {
		if !strings.Contains(listed(t, byName, name).Description, "REPORT") {
			t.Errorf("%s: description must tell the agent to REPORT the skipped entries and their reasons", name)
		}
	}
}

// schemaOf decodes the input schema of a listed tool.
func schemaOf(t *testing.T, tool *mcp.Tool) map[string]any {
	t.Helper()
	body, err := json.Marshal(tool.InputSchema)
	if err != nil {
		t.Fatal(err)
	}
	var schema map[string]any
	if err := json.Unmarshal(body, &schema); err != nil {
		t.Fatal(err)
	}
	return schema
}

func property(t *testing.T, schema map[string]any, name string) map[string]any {
	t.Helper()
	properties, _ := schema["properties"].(map[string]any)
	property, ok := properties[name].(map[string]any)
	if !ok {
		t.Fatalf("schema has no property %q: %v", name, schema)
	}
	return property
}

// hasType reports whether a schema has exactly this JSON type. The type is a
// single string: some clients refuse a schema whose type is an array.
func hasType(schema map[string]any, want string) bool {
	kind, ok := schema["type"].(string)
	return ok && kind == want
}

// closed reports whether an object schema refuses properties it does not list.
func closed(schema map[string]any) bool {
	return schema["additionalProperties"] == false
}

func requireDescription(t *testing.T, path string, schema map[string]any) {
	t.Helper()
	if text, _ := schema["description"].(string); len(text) < 20 {
		t.Errorf("%s: description %q is too short, an agent fills the field by it", path, text)
	}
}

func TestAddWordsSchemaDescribesEveryField(t *testing.T) {
	schema := schemaOf(t, listed(t, listTools(t, connect(t, &fakeDoor{})), "add_words"))

	words := property(t, schema, "words")
	requireDescription(t, "words", words)
	item, _ := words["items"].(map[string]any)
	if item == nil {
		t.Fatalf("words has no items schema: %v", words)
	}
	spelling := property(t, item, "spelling")
	requireDescription(t, "words[].spelling", spelling)
	if !hasType(spelling, "string") {
		t.Errorf("spelling: %v, want a string", spelling)
	}
	forceCase := property(t, item, "force_case")
	requireDescription(t, "words[].force_case", forceCase)
	if !hasType(forceCase, "boolean") {
		t.Errorf("force_case: %v, want a boolean", forceCase)
	}
	variants := property(t, item, "variants")
	requireDescription(t, "words[].variants", variants)
	for _, language := range []string{"ru", "en"} {
		list := property(t, variants, language)
		requireDescription(t, "words[].variants."+language, list)
		if !hasType(list, "array") {
			t.Errorf("variants.%s: %v, want an array", language, list)
		}
		element, _ := list["items"].(map[string]any)
		if element == nil || !hasType(element, "string") {
			t.Errorf("variants.%s: items = %v, want strings", language, list["items"])
		}
	}

	for path, object := range map[string]map[string]any{"add_words": schema, "words[]": item, "words[].variants": variants} {
		if !hasType(object, "object") || !closed(object) {
			t.Errorf("%s: %v, want a closed object", path, object)
		}
	}

	// Only the spelling is needed: variants and force_case may be left out,
	// and so may either language.
	required := func(schema map[string]any) []any {
		list, _ := schema["required"].([]any)
		return list
	}
	if got := required(item); len(got) != 1 || got[0] != "spelling" {
		t.Errorf("a word requires %v, want only spelling", got)
	}
	if got := required(variants); len(got) != 0 {
		t.Errorf("variants requires %v, want nothing: one language is enough", got)
	}
	if got := required(schema); len(got) != 1 || got[0] != "words" {
		t.Errorf("add_words requires %v, want only words", got)
	}
}

func TestOtherWriteSchemasDescribeEveryField(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))

	pack := schemaOf(t, listed(t, byName, "set_pack_enabled"))
	id, enabled := property(t, pack, "id"), property(t, pack, "enabled")
	requireDescription(t, "set_pack_enabled.id", id)
	requireDescription(t, "set_pack_enabled.enabled", enabled)
	if !hasType(id, "string") || !hasType(enabled, "boolean") {
		t.Errorf("id = %v, enabled = %v, want a string and a boolean", id, enabled)
	}
	// An agent that forgets `enabled` must be stopped, not read as false.
	if required, _ := pack["required"].([]any); len(required) != 2 {
		t.Errorf("set_pack_enabled requires %v, want id and enabled", required)
	}

	remove := schemaOf(t, listed(t, byName, "remove_words"))
	spellings := property(t, remove, "spellings")
	requireDescription(t, "remove_words.spellings", spellings)
	if element, _ := spellings["items"].(map[string]any); element == nil || !hasType(element, "string") {
		t.Errorf("spellings: items = %v, want strings", spellings["items"])
	}

	revert := schemaOf(t, listed(t, byName, "revert_agent_words"))
	if properties, _ := revert["properties"].(map[string]any); len(properties) != 0 {
		t.Errorf("revert_agent_words takes no arguments, schema has %v", properties)
	}
	for name, schema := range map[string]map[string]any{"set_pack_enabled": pack, "remove_words": remove, "revert_agent_words": revert} {
		if !hasType(schema, "object") || !closed(schema) {
			t.Errorf("%s: %v, want a closed object", name, schema)
		}
	}
}

func TestAddWordsRejectsEmptyList(t *testing.T) {
	d := &fakeDoor{}
	result := callWrite(t, connect(t, d), "add_words", map[string]any{"words": []any{}})
	if !result.IsError {
		t.Fatalf("want a tool error, got %s", text(t, result))
	}
	if got := text(t, result); !strings.Contains(got, "пуст") {
		t.Fatalf("text = %q, want the reason in Russian: the list is empty", got)
	}
	untouched(t, d)
}

func TestAddWordsRejectsMissingList(t *testing.T) {
	d := &fakeDoor{}
	session := connect(t, d)
	// Whatever the shape of the refusal, the door must not be reached.
	result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "add_words", Arguments: map[string]any{}})
	if err == nil && (result == nil || !result.IsError) {
		t.Fatalf("a call without words was accepted: %v", result)
	}
	untouched(t, d)
}

func TestAddWordsRejectsOverFifty(t *testing.T) {
	d := &fakeDoor{}
	result := callWrite(t, connect(t, d), "add_words", map[string]any{"words": words(51)})
	if !result.IsError {
		t.Fatalf("want a tool error, got %s", text(t, result))
	}
	got := text(t, result)
	// The person reads this through the agent: the limit, what was sent, what to do.
	for _, want := range []string{"50", "51", "Разбейте"} {
		if !strings.Contains(got, want) {
			t.Errorf("text = %q, want it to contain %q", got, want)
		}
	}
	untouched(t, d)
}

func TestAddWordsAcceptsExactlyFifty(t *testing.T) {
	d := &fakeDoor{data: map[string]string{"add_words": `{"added":[],"skipped":{}}`}}
	result := callWrite(t, connect(t, d), "add_words", map[string]any{"words": words(50)})
	if result.IsError {
		t.Fatalf("fifty words is the limit and must pass: %s", text(t, result))
	}
	if len(d.calls) != 1 {
		t.Fatalf("the door was asked %d times, want 1", len(d.calls))
	}
	var sent struct{ Words []json.RawMessage }
	if err := json.Unmarshal([]byte(sentArgs(t, d, 0)), &sent); err != nil || len(sent.Words) != 50 {
		t.Fatalf("the door got %d words (%v), want 50", len(sent.Words), err)
	}
}

func TestAddWordsReportsSkippedWithReason(t *testing.T) {
	// The word is added and its bad variant is dropped with the reason: the
	// agent has to see both to tell the person.
	const data = `{"added":["арипипразол","Tranq"],"skipped":{"арипипразол / ари":"вариант «ари» короче двух символов","Kubernetes":"повтор в этом запросе"}}`
	d := &fakeDoor{data: map[string]string{"add_words": data}}
	result := callWrite(t, connect(t, d), "add_words", map[string]any{"words": []any{
		map[string]any{"spelling": "арипипразол", "variants": map[string]any{"ru": []any{"ари", "ари пипразол"}}},
		map[string]any{"spelling": "Tranq"},
		map[string]any{"spelling": "Kubernetes"},
		map[string]any{"spelling": "kubernetes"},
	}})
	if result.IsError {
		t.Fatalf("unexpected tool error: %s", text(t, result))
	}
	got := text(t, result)
	if got != data {
		t.Fatalf("text = %s, want the door's data as it came: %s", got, data)
	}
	var answer struct {
		Added   []string
		Skipped map[string]string
	}
	if err := json.Unmarshal([]byte(got), &answer); err != nil {
		t.Fatal(err)
	}
	if len(answer.Added) != 2 || answer.Skipped["арипипразол / ари"] != "вариант «ари» короче двух символов" {
		t.Fatalf("answer = %+v, want two added words and the reason of the dropped variant", answer)
	}
}

func TestAddWordsSendsTheWireShape(t *testing.T) {
	d := &fakeDoor{data: map[string]string{"add_words": `{"added":[],"skipped":{}}`}}
	session := connect(t, d)
	// The door's protocol has every word as {spelling, variants:{ru,en}, force_case}.
	// The agent may leave out variants, a language, and force_case.
	callWrite(t, session, "add_words", map[string]any{"words": []any{
		map[string]any{"spelling": "арипипразол", "variants": map[string]any{"ru": []any{"ари пипразол"}}},
		map[string]any{"spelling": "Tranq"},
		map[string]any{"spelling": "iOS", "variants": map[string]any{"en": []any{"eye oh es"}}, "force_case": true},
		map[string]any{"spelling": "SQL", "variants": map[string]any{}, "force_case": false},
	}})
	if len(d.calls) != 1 || d.calls[0] != "add_words" {
		t.Fatalf("the door was asked %q, want add_words once", d.calls)
	}
	const want = `{"words":[` +
		`{"spelling":"арипипразол","variants":{"ru":["ари пипразол"],"en":[]},"force_case":false},` +
		`{"spelling":"Tranq","variants":{"ru":[],"en":[]},"force_case":false},` +
		`{"spelling":"iOS","variants":{"ru":[],"en":["eye oh es"]},"force_case":true},` +
		`{"spelling":"SQL","variants":{"ru":[],"en":[]},"force_case":false}]}`
	if got := sentArgs(t, d, 0); got != want {
		t.Fatalf("args =\n%s\nwant\n%s", got, want)
	}
}

func TestAddWordsWithPackIdSendsItLast(t *testing.T) {
	d := &fakeDoor{data: map[string]string{"add_words": `{"added":["Ableton"],"skipped":{}}`}}
	callWrite(t, connect(t, d), "add_words", map[string]any{
		"words": []any{map[string]any{"spelling": "Ableton"}}, "pack_id": "agent-3f9a12bc",
	})
	const want = `{"words":[{"spelling":"Ableton","variants":{"ru":[],"en":[]},"force_case":false}],"pack_id":"agent-3f9a12bc"}`
	if got := sentArgs(t, d, 0); got != want {
		t.Fatalf("args =\n%s\nwant\n%s", got, want)
	}
}

func TestBlankPackIdReachesTheDoor(t *testing.T) {
	// An empty pack_id must not be read as a missing one: the door refuses it,
	// and the words do not land in the personal dictionary by accident.
	d := &fakeDoor{data: map[string]string{"add_words": `{"added":[],"skipped":{}}`, "remove_words": `{"removed":[],"skipped":{}}`}}
	session := connect(t, d)
	callWrite(t, session, "add_words", map[string]any{"words": []any{map[string]any{"spelling": "Ableton"}}, "pack_id": ""})
	callWrite(t, session, "remove_words", map[string]any{"spellings": []any{"Ableton"}, "pack_id": ""})
	if got, want := sentArgs(t, d, 0), `{"words":[{"spelling":"Ableton","variants":{"ru":[],"en":[]},"force_case":false}],"pack_id":""}`; got != want {
		t.Fatalf("add_words args = %s, want %s", got, want)
	}
	if got, want := sentArgs(t, d, 1), `{"spellings":["Ableton"],"pack_id":""}`; got != want {
		t.Fatalf("remove_words args = %s, want %s", got, want)
	}
}

func TestRemoveWordsWithPackIdSendsIt(t *testing.T) {
	d := &fakeDoor{data: map[string]string{"remove_words": `{"removed":["Ableton"],"skipped":{}}`}}
	callWrite(t, connect(t, d), "remove_words", map[string]any{"spellings": []any{"Ableton"}, "pack_id": "agent-3f9a12bc"})
	if got, want := sentArgs(t, d, 0), `{"spellings":["Ableton"],"pack_id":"agent-3f9a12bc"}`; got != want {
		t.Fatalf("args = %s, want %s", got, want)
	}
}

func TestPackIdIsAnOptionalDescribedString(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	for _, name := range []string{"add_words", "remove_words"} {
		schema := schemaOf(t, listed(t, byName, name))
		packID := property(t, schema, "pack_id")
		requireDescription(t, name+".pack_id", packID)
		if !hasType(packID, "string") {
			t.Errorf("%s.pack_id: %v, want a string", name, packID)
		}
		for _, field := range schema["required"].([]any) {
			if field == "pack_id" {
				t.Errorf("%s requires pack_id, it must stay optional", name)
			}
		}
	}
}

func TestAddWordsDoesNotRepeatTheStoresValidation(t *testing.T) {
	// An empty spelling, an empty variant and a variant equal to the spelling
	// are the app's to judge and report in skipped: they all go through.
	d := &fakeDoor{data: map[string]string{"add_words": `{"added":[],"skipped":{}}`}}
	result := callWrite(t, connect(t, d), "add_words", map[string]any{"words": []any{
		map[string]any{"spelling": ""},
		map[string]any{"spelling": "Tranq", "variants": map[string]any{"ru": []any{"", "Tranq", "т"}}},
	}})
	if result.IsError || len(d.calls) != 1 {
		t.Fatalf("IsError = %v, door asked %d times, want the batch sent as it is", result.IsError, len(d.calls))
	}
	const want = `{"words":[{"spelling":"","variants":{"ru":[],"en":[]},"force_case":false},` +
		`{"spelling":"Tranq","variants":{"ru":["","Tranq","т"],"en":[]},"force_case":false}]}`
	if got := sentArgs(t, d, 0); got != want {
		t.Fatalf("args =\n%s\nwant\n%s", got, want)
	}
}

func TestNullIsRefusedWithTheFieldNamed(t *testing.T) {
	// The schemas are plain: one type per field, no null next to it, because
	// some clients cannot read a type that is an array. An explicit null is
	// therefore a schema violation, and the answer names the field.
	d := &fakeDoor{}
	session := connect(t, d)
	for name, tc := range map[string]struct {
		tool  string
		args  map[string]any
		field string
	}{
		"words":                   {"add_words", map[string]any{"words": nil}, "words"},
		"variants":                {"add_words", map[string]any{"words": []any{map[string]any{"spelling": "Tranq", "variants": nil}}}, "variants"},
		"ru":                      {"add_words", map[string]any{"words": []any{map[string]any{"spelling": "Tranq", "variants": map[string]any{"ru": nil}}}}, "ru"},
		"force_case":              {"add_words", map[string]any{"words": []any{map[string]any{"spelling": "Tranq", "force_case": nil}}}, "force_case"},
		"spellings":               {"remove_words", map[string]any{"spellings": nil}, "spellings"},
		"enabled":                 {"set_pack_enabled", map[string]any{"id": "it", "enabled": nil}, "enabled"},
		"pack_id of add_words":    {"add_words", map[string]any{"words": []any{map[string]any{"spelling": "Tranq"}}, "pack_id": nil}, "pack_id"},
		"pack_id of remove_words": {"remove_words", map[string]any{"spellings": []any{"Tranq"}, "pack_id": nil}, "pack_id"},
		"title":                   {"create_pack", map[string]any{"title": nil}, "title"},
		"id of delete_pack":       {"delete_pack", map[string]any{"id": nil}, "id"},
	} {
		t.Run(name, func(t *testing.T) {
			result := callWrite(t, session, tc.tool, tc.args)
			if !result.IsError || !strings.Contains(text(t, result), tc.field) {
				t.Fatalf("IsError = %v, text = %q, want a tool error that names %q", result.IsError, text(t, result), tc.field)
			}
		})
	}
	untouched(t, d)
}

func TestWriteToolsSurviveUnknownFields(t *testing.T) {
	// An agent may add a field of its own at any level. It must not crash the
	// server, and it must not be dropped quietly either: a misspelled
	// forceCase read as the default would lose what the person asked for.
	// The schema is closed, so the call comes back as a tool error that names
	// the field, and the door is not asked.
	d := &fakeDoor{data: map[string]string{"add_words": `{"added":["Tranq"],"skipped":{}}`}}
	session := connect(t, d)
	for name, tc := range map[string]struct {
		tool  string
		args  map[string]any
		field string
	}{
		"top level of add_words": {"add_words", map[string]any{
			"words": []any{map[string]any{"spelling": "Tranq"}}, "comment": "x",
		}, "comment"},
		"inside a word": {"add_words", map[string]any{
			"words": []any{map[string]any{"spelling": "Tranq", "forceCase": true}},
		}, "forceCase"},
		"inside variants": {"add_words", map[string]any{
			"words": []any{map[string]any{"spelling": "Tranq", "variants": map[string]any{"de": []any{"x"}}}},
		}, "de"},
		"set_pack_enabled":   {"set_pack_enabled", map[string]any{"id": "it", "enabled": true, "force": true}, "force"},
		"remove_words":       {"remove_words", map[string]any{"spellings": []any{"Tranq"}, "all": true}, "all"},
		"revert_agent_words": {"revert_agent_words", map[string]any{"everything": true}, "everything"},
		"create_pack":        {"create_pack", map[string]any{"title": "Музыка", "id": "x"}, "id"},
		"delete_pack":        {"delete_pack", map[string]any{"id": "agent-3f9a12bc", "force": true}, "force"},
	} {
		t.Run(name, func(t *testing.T) {
			result := callWrite(t, session, tc.tool, tc.args)
			if !result.IsError || !strings.Contains(text(t, result), tc.field) {
				t.Fatalf("IsError = %v, text = %q, want a tool error that names %q", result.IsError, text(t, result), tc.field)
			}
		})
	}
	untouched(t, d)
	// The server is still serving.
	again := callWrite(t, session, "add_words", map[string]any{"words": []any{map[string]any{"spelling": "Tranq"}}})
	if again.IsError {
		t.Fatalf("the next call failed: %s", text(t, again))
	}
}

func TestSetPackEnabledSendsIdAndEnabled(t *testing.T) {
	const data = `{"id":"medicine","title":"Медицина","word_count":80,"enabled":%t}`
	for _, enabled := range []bool{true, false} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			// The door says by itself that false is a disabling: the args hold
			// the id and enabled, nothing else.
			answer := fmt.Sprintf(data, enabled)
			d := &fakeDoor{data: map[string]string{"set_pack": answer}}
			result := callWrite(t, connect(t, d), "set_pack_enabled", map[string]any{"id": "medicine", "enabled": enabled})
			if result.IsError {
				t.Fatalf("unexpected tool error: %s", text(t, result))
			}
			if got := text(t, result); got != answer {
				t.Fatalf("text = %s, want %s", got, answer)
			}
			if len(d.calls) != 1 || d.calls[0] != "set_pack" {
				t.Fatalf("the door was asked %q, want set_pack once: the command is not named like the tool", d.calls)
			}
			if got, want := sentArgs(t, d, 0), fmt.Sprintf(`{"id":"medicine","enabled":%t}`, enabled); got != want {
				t.Fatalf("args = %s, want %s", got, want)
			}
		})
	}
}

func TestSetPackEnabledNeedsAnExplicitChoice(t *testing.T) {
	d := &fakeDoor{}
	result, err := connect(t, d).CallTool(context.Background(), &mcp.CallToolParams{
		Name: "set_pack_enabled", Arguments: map[string]any{"id": "medicine"},
	})
	if err == nil && (result == nil || !result.IsError) {
		t.Fatalf("a call without enabled was accepted: it would have been read as a disabling: %v", result)
	}
	untouched(t, d)
}

func TestRemoveWordsSendsSpellings(t *testing.T) {
	const data = `{"removed":["арипипразол"],"skipped":{"Tranq":"слово добавил человек, снять его можно в приложении"}}`
	d := &fakeDoor{data: map[string]string{"remove_words": data}}
	result := callWrite(t, connect(t, d), "remove_words", map[string]any{"spellings": []any{"арипипразол", "Tranq"}})
	if result.IsError {
		t.Fatalf("unexpected tool error: %s", text(t, result))
	}
	if got := text(t, result); got != data {
		t.Fatalf("text = %s, want %s", got, data)
	}
	if len(d.calls) != 1 || d.calls[0] != "remove_words" {
		t.Fatalf("the door was asked %q, want remove_words once", d.calls)
	}
	if got, want := sentArgs(t, d, 0), `{"spellings":["арипипразол","Tranq"]}`; got != want {
		t.Fatalf("args = %s, want %s", got, want)
	}
}

func TestRevertAgentWordsTakesNoArguments(t *testing.T) {
	const data = `{"removed_words":12,"removed_variants":3}`
	d := &fakeDoor{data: map[string]string{"revert_agent_words": data}}
	session := connect(t, d)
	for _, arguments := range []any{nil, map[string]any{}} {
		result := callWrite(t, session, "revert_agent_words", arguments)
		if result.IsError {
			t.Fatalf("unexpected tool error: %s", text(t, result))
		}
		if got := text(t, result); got != data {
			t.Fatalf("text = %s, want %s", got, data)
		}
	}
	for i, cmd := range d.calls {
		if cmd != "revert_agent_words" {
			t.Fatalf("call %d asked %q, want revert_agent_words", i, cmd)
		}
		if got := sentArgs(t, d, i); got != "null" {
			// The client turns nothing into an empty object on the wire.
			t.Fatalf("call %d: args = %s, want none", i, got)
		}
	}
	if len(d.calls) != 2 {
		t.Fatalf("the door was asked %d times, want 2", len(d.calls))
	}
}

func TestWriteToolsCarryDoorRefusalAsIs(t *testing.T) {
	const message = "Выключение набора требует полного доступа. Включите его в настройках Tranq."
	arguments := map[string]map[string]any{
		"set_pack_enabled":   {"id": "it", "enabled": false},
		"add_words":          {"words": []any{map[string]any{"spelling": "Tranq"}}},
		"remove_words":       {"spellings": []any{"Tranq"}},
		"revert_agent_words": {},
		"create_pack":        {"title": "Музыка"},
		"delete_pack":        {"id": "agent-3f9a12bc"},
	}
	for _, name := range writeToolNames {
		t.Run(name, func(t *testing.T) {
			d := &fakeDoor{err: &door.Refusal{Message: message, Language: "ru"}}
			result := callWrite(t, connect(t, d), name, arguments[name])
			if !result.IsError {
				t.Fatalf("a refusal of the door is a tool error, got %s", text(t, result))
			}
			if got := text(t, result); got != message {
				t.Fatalf("text = %q, want the door's text %q", got, message)
			}
		})
	}
}

func TestWriteToolsStartTheAppWhenDoorIsDown(t *testing.T) {
	d := &fakeDoor{downFor: 1, data: map[string]string{"add_words": `{"added":["Tranq"],"skipped":{}}`}}
	result := callWrite(t, connect(t, d), "add_words", map[string]any{"words": []any{map[string]any{"spelling": "Tranq"}}})
	if result.IsError {
		t.Fatalf("unexpected tool error: %s", text(t, result))
	}
	if d.ensured != 1 || len(d.calls) != 2 {
		t.Fatalf("EnsureApp called %d times and the door %d times, want 1 and 2", d.ensured, len(d.calls))
	}
	// The first call never reached the door, so asking again cannot add a word twice.
	if sentArgs(t, d, 0) != sentArgs(t, d, 1) {
		t.Fatalf("the retry sent other args: %s and %s", sentArgs(t, d, 0), sentArgs(t, d, 1))
	}
}
