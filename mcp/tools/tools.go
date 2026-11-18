// Package tools holds the MCP tools of the Tranq server. A tool validates what
// the agent sent, asks the app through the door and hands the answer back;
// the app is the only writer of the dictionary.
//
// One file per tool group. A group exposes one register function and is
// listed in Register: adding a group is one line there.
package tools

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/Nuteres/Tranq/mcp/door"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Door is what the tools need from the door client. *door.Client satisfies it;
// tests use fakes.
type Door interface {
	// Call sends one command and returns the data of the answer.
	Call(ctx context.Context, cmd string, args any) (json.RawMessage, error)
	// EnsureApp opens the app and waits for its door when it is closed.
	EnsureApp(ctx context.Context) error
}

// Register adds every tool of the server to s.
func Register(s *mcp.Server, d Door) {
	registerRead(s, d)
}

// ask sends a command to the door and returns the data as the text of a tool
// result. When the door is unreachable it opens the app once and tries again.
//
// An error comes back as a tool error: the SDK puts its text into the result
// as is, and the agent shows it to the human. That is why door refusals and
// "open Tranq" are returned untouched.
func ask(ctx context.Context, d Door, cmd string, args any) (*mcp.CallToolResult, any, error) {
	data, err := d.Call(ctx, cmd, args)
	if errors.Is(err, door.ErrUnavailable) {
		if err = d.EnsureApp(ctx); err == nil {
			data, err = d.Call(ctx, cmd, args)
		}
	}
	if err != nil {
		return nil, nil, err
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(data)}}}, nil, nil
}
