package tools

import (
	"context"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const listDictionaryPacksDescription = "List the built-in dictionary packs of Tranq, a macOS dictation app that turns " +
	"spoken Russian, with Latin technical terms, into clean text. A pack is a ready-made vocabulary for one " +
	"field, such as IT, medicine or law: it tells Tranq how to spell the terms and names of that field after " +
	"speech recognition.\n\n" +
	"Call this tool when the user asks which vocabularies Tranq has or which of them are switched on, and " +
	"before adding words yourself, to see whether a pack already covers the field. The result lists packs " +
	"only. The words inside a built-in pack are not exposed by this server, so you cannot check whether a pack " +
	"contains a given term. The user's own words are not part of the result either, for those use " +
	"list_user_words.\n\n" +
	"Takes no arguments. Returns a JSON array with one object per pack. Fields of each object:\n" +
	"- `id`: stable identifier of the pack, for example \"it\"; the value other tools take to refer to the pack.\n" +
	"- `title`: display name of the pack, in the language of the Tranq interface, Russian or English.\n" +
	"- `word_count`: number of terms the pack contains.\n" +
	"- `enabled`: true if the pack is applied to dictation now, false if the user switched it off.\n" +
	"- `source`: `builtin` for a pack that comes with Tranq, `agent` for a pack an agent made with " +
	"create_pack. The words of an agent pack are read with list_pack_words.\n\n" +
	"Read-only: nothing is changed."

const listUserWordsDescription = "List the user's own dictionary words in Tranq, a macOS dictation app that turns " +
	"spoken Russian, with Latin technical terms, into clean text. A word is one correct spelling, such as a " +
	"product name, a surname, a term or an abbreviation, together with the variants the speech recognizer " +
	"tends to produce instead. When a variant appears in the recognized text, Tranq writes the spelling.\n\n" +
	"Call this tool before adding words, to avoid duplicates and to see how the user already spells things, " +
	"and when the user asks what is in their dictionary, which words work or which are never used. Words " +
	"that belong to built-in packs are not included, and the contents of packs are not exposed by this " +
	"server: list_dictionary_packs shows only which packs exist and whether they are switched on. The list " +
	"can be long.\n\n" +
	"Takes no arguments. Returns a JSON array with one object per word. Fields of each object:\n" +
	"- `spelling`: the correct form that ends up in the text, with its exact capitalization.\n" +
	"- `variants`: an object with two lists of strings, `ru` and `en`: the sound-alike forms the recognizer " +
	"produces when the word is spoken in Russian speech and in English speech. A list is empty when there are none.\n" +
	"- `source`: who created the word. `manual` means the user typed it in the Tranq app. `learned` means " +
	"Tranq picked it up by itself from corrections the user made to dictated notes. `mcp` means an AI agent " +
	"added it through this server; revert_agent_words rolls back all such words in one call.\n" +
	"- `hits`: how many times Tranq applied the word to a dictation; 0 means it was never used.\n" +
	"- `last_used`: date and time of the latest use as an ISO 8601 string, or null if the word was never used.\n\n" +
	"Read-only: nothing is changed."

// noArguments is the input of tools that take none: the input schema becomes
// an empty object, and an agent may send {} or nothing at all.
type noArguments struct{}

// readOnly marks a tool that changes nothing and talks only to the local app.
func readOnly(title string) *mcp.ToolAnnotations {
	closedWorld := false
	return &mcp.ToolAnnotations{Title: title, ReadOnlyHint: true, OpenWorldHint: &closedWorld}
}

func registerRead(s *mcp.Server, d Door) {
	mcp.AddTool(s, &mcp.Tool{
		Name:        "list_dictionary_packs",
		Description: listDictionaryPacksDescription,
		Annotations: readOnly("List dictionary packs"),
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ noArguments) (*mcp.CallToolResult, any, error) {
		return ask(ctx, d, "packs", nil)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "list_user_words",
		Description: listUserWordsDescription,
		Annotations: readOnly("List user words"),
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ noArguments) (*mcp.CallToolResult, any, error) {
		return ask(ctx, d, "words", nil)
	})
}
