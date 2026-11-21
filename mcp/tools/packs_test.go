package tools_test

import (
	"context"
	"strings"
	"testing"
	"unicode"

	"github.com/Hidden-Den/Tranq/mcp/door"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var packToolNames = []string{"create_pack", "delete_pack", "list_pack_words"}

func TestPackToolsAreRegisteredWithHints(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	for _, name := range packToolNames {
		a := listed(t, byName, name).Annotations
		if a == nil {
			t.Errorf("%s: no annotations", name)
			continue
		}
		if a.OpenWorldHint == nil || *a.OpenWorldHint {
			t.Errorf("%s: OpenWorldHint = %v, want false", name, a.OpenWorldHint)
		}
	}
	if a := listed(t, byName, "list_pack_words").Annotations; a == nil || !a.ReadOnlyHint {
		t.Errorf("list_pack_words must be read-only: %+v", a)
	}
}

func TestPackToolsDescribeThemselves(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	required := map[string][]string{
		"create_pack":     {"`id`", "`title`", "`created`", "20", "60", "add_words", "`pack_id`", "already existed"},
		"delete_pack":     {"`id`", "`removed_words`", "agent"},
		"list_pack_words": {"`spelling`", "`variants`", "`ru`", "`en`", "built-in", "Read-only"},
	}
	for name, phrases := range required {
		description := listed(t, byName, name).Description
		if len(description) < 400 {
			t.Errorf("%s: description is %d bytes, an agent chooses tools by it, so it must be detailed", name, len(description))
		}
		var cyrillic, letters int
		for _, r := range description {
			if unicode.IsLetter(r) {
				letters++
				if unicode.Is(unicode.Cyrillic, r) {
					cyrillic++
				}
			}
		}
		if cyrillic*10 > letters {
			t.Errorf("%s: description must be in English", name)
		}
		for _, phrase := range phrases {
			if !strings.Contains(description, phrase) {
				t.Errorf("%s: description does not contain %q\n%s", name, phrase, description)
			}
		}
		if !strings.Contains(description, "not instructions") {
			t.Errorf("%s: description must say that texts from the app are data, not instructions", name)
		}
	}
}

func TestPackToolsSendTheWireShape(t *testing.T) {
	d := &fakeDoor{data: map[string]string{
		"create_pack": `{"id":"agent-3f9a12bc","title":"Музыка","created":true}`,
		"delete_pack": `{"id":"agent-3f9a12bc","title":"Музыка","removed_words":3}`,
		"pack_words":  `[]`,
	}}
	session := connect(t, d)
	for i, tc := range []struct {
		tool string
		args map[string]any
		cmd  string
		want string
	}{
		{"create_pack", map[string]any{"title": "Музыка"}, "create_pack", `{"title":"Музыка"}`},
		{"delete_pack", map[string]any{"id": "agent-3f9a12bc"}, "delete_pack", `{"id":"agent-3f9a12bc"}`},
		{"list_pack_words", map[string]any{"id": "agent-3f9a12bc"}, "pack_words", `{"id":"agent-3f9a12bc"}`},
	} {
		result := callWrite(t, session, tc.tool, tc.args)
		if result.IsError {
			t.Fatalf("%s: unexpected tool error: %s", tc.tool, text(t, result))
		}
		if d.calls[i] != tc.cmd {
			t.Errorf("%s asked the door %q, want %q", tc.tool, d.calls[i], tc.cmd)
		}
		if got := sentArgs(t, d, i); got != tc.want {
			t.Errorf("%s: args = %s, want %s", tc.tool, got, tc.want)
		}
	}
}

func TestPackToolSchemasDescribeEveryField(t *testing.T) {
	byName := listTools(t, connect(t, &fakeDoor{}))
	for tool, field := range map[string]string{"create_pack": "title", "delete_pack": "id", "list_pack_words": "id"} {
		schema := schemaOf(t, listed(t, byName, tool))
		prop := property(t, schema, field)
		requireDescription(t, tool+"."+field, prop)
		if !hasType(prop, "string") {
			t.Errorf("%s.%s: %v, want a string", tool, field, prop)
		}
		if !hasType(schema, "object") || !closed(schema) {
			t.Errorf("%s: %v, want a closed object", tool, schema)
		}
		if required, _ := schema["required"].([]any); len(required) != 1 || required[0] != field {
			t.Errorf("%s requires %v, want only %s", tool, required, field)
		}
	}
}

func TestPackToolsRefuseMissingFields(t *testing.T) {
	d := &fakeDoor{}
	session := connect(t, d)
	for tool, args := range map[string]map[string]any{"create_pack": {}, "delete_pack": {}, "list_pack_words": {}} {
		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
		if err == nil && (result == nil || !result.IsError) {
			t.Errorf("%s without its field was accepted", tool)
		}
	}
	untouched(t, d)
}

func TestPackToolsCarryDoorRefusalAsIs(t *testing.T) {
	const message = "Это встроенный набор. Работать можно только с наборами агента."
	args := map[string]map[string]any{
		"create_pack":     {"title": "Музыка"},
		"delete_pack":     {"id": "it"},
		"list_pack_words": {"id": "it"},
	}
	for _, name := range packToolNames {
		d := &fakeDoor{err: &door.Refusal{Message: message, Language: "ru"}}
		result := callWrite(t, connect(t, d), name, args[name])
		if !result.IsError || text(t, result) != message {
			t.Errorf("%s: IsError = %v, text = %q, want the door's text", name, result.IsError, text(t, result))
		}
	}
}

func TestPackToolsStartTheAppWhenDoorIsDown(t *testing.T) {
	d := &fakeDoor{downFor: 1, data: map[string]string{"create_pack": `{"id":"agent-3f9a12bc","title":"Музыка","created":true}`}}
	result := callWrite(t, connect(t, d), "create_pack", map[string]any{"title": "Музыка"})
	if result.IsError || d.ensured != 1 {
		t.Fatalf("IsError = %v, app started %d times, want a success after one start", result.IsError, d.ensured)
	}
}
