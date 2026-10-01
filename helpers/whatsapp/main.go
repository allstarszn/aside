// aside's WhatsApp helper: a linked device (the protocol WhatsApp Web uses)
// that speaks JSON lines, so the Swift app never links against Go.
//
//	stdin:  {"cmd":"send","chat":"<id>","text":"..."}  {"cmd":"quit"}
//	stdout: qr, linked, ready, message, sent, error events, one per line
//
// argv[1] is the session database path.
package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

type event struct {
	Type    string  `json:"type"`
	Code    string  `json:"code,omitempty"`
	ID      string  `json:"id,omitempty"`
	Chat    string  `json:"chat,omitempty"`
	Sender  string  `json:"sender,omitempty"`
	Text    string  `json:"text,omitempty"`
	Date    int64   `json:"date,omitempty"`
	FromMe  *bool   `json:"fromMe,omitempty"`
	Group   *string `json:"group,omitempty"`
	OK      *bool   `json:"ok,omitempty"`
	Message string  `json:"message,omitempty"`
}

var outMu sync.Mutex

// emit is the only writer to stdout: events come from several goroutines and
// two interleaved lines would be unparseable.
func emit(e event) {
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	outMu.Lock()
	defer outMu.Unlock()
	fmt.Println(string(b))
}

func fail(msg string) {
	emit(event{Type: "error", Message: msg})
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fail("missing session database path")
	}
	ctx := context.Background()

	// 🔴 All four of these are load-bearing. Without the busy timeout, WAL and a
	// single connection, every key save fails with SQLITE_BUSY and linking hangs.
	dsn := "file:" + (&url.URL{Path: os.Args[1]}).EscapedPath() +
		"?_pragma=foreign_keys(1)&_pragma=busy_timeout(15000)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		fail("open session: " + err.Error())
	}
	db.SetMaxOpenConns(1)
	container := sqlstore.NewWithDB(db, "sqlite", waLog.Noop)
	if err := container.Upgrade(ctx); err != nil {
		fail("session upgrade: " + err.Error())
	}
	dev, err := container.GetFirstDevice(ctx)
	if err != nil {
		fail("session device: " + err.Error())
	}
	client := whatsmeow.NewClient(dev, waLog.Noop)

	client.AddEventHandler(func(raw interface{}) {
		switch e := raw.(type) {
		case *events.Message:
			handleMessage(ctx, client, e)
		case *events.Connected:
			emit(event{Type: "ready"})
		}
	})

	if client.Store.ID == nil {
		qr, err := client.GetQRChannel(ctx)
		if err != nil {
			fail("qr channel: " + err.Error())
		}
		if err := client.Connect(); err != nil {
			fail("connect: " + err.Error())
		}
		go func() {
			for evt := range qr {
				switch evt.Event {
				case "code":
					emit(event{Type: "qr", Code: evt.Code})
				case "success":
					emit(event{Type: "linked"})
				case "timeout":
					emit(event{Type: "error", Message: "the QR code expired"})
				}
			}
		}()
	} else if err := client.Connect(); err != nil {
		fail("connect: " + err.Error())
	}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var cmd struct {
			Cmd  string `json:"cmd"`
			Chat string `json:"chat"`
			Text string `json:"text"`
		}
		if json.Unmarshal(sc.Bytes(), &cmd) != nil {
			continue
		}
		switch cmd.Cmd {
		case "quit":
			client.Disconnect()
			return
		case "send":
			send(ctx, client, cmd.Chat, cmd.Text)
		}
	}
	// stdin closing means the app is gone: do not linger as an orphan.
	client.Disconnect()
}

func send(ctx context.Context, client *whatsmeow.Client, chat, text string) {
	// The id is whatever the message event reported (often 1234@lid), so it is
	// parsed as-is and never rebuilt from a phone number.
	jid, err := types.ParseJID(chat)
	if err != nil {
		f := false
		emit(event{Type: "sent", OK: &f, Message: "bad chat id: " + err.Error()})
		return
	}
	sctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	_, err = client.SendMessage(sctx, jid, &waE2E.Message{Conversation: proto.String(text)})
	ok := err == nil
	e := event{Type: "sent", OK: &ok}
	if err != nil {
		e.Message = err.Error()
	}
	emit(e)
}

func handleMessage(ctx context.Context, client *whatsmeow.Client, m *events.Message) {
	text := m.Message.GetConversation()
	if text == "" {
		text = m.Message.GetExtendedTextMessage().GetText()
	}
	if text == "" {
		return
	}
	group := ""
	if m.Info.IsGroup {
		if info, err := client.GetGroupInfo(ctx, m.Info.Chat); err == nil {
			group = info.Name
		}
	}
	fromMe := m.Info.IsFromMe
	emit(event{
		Type: "message", ID: m.Info.ID, Chat: m.Info.Chat.String(),
		Sender: m.Info.PushName, Text: text, Date: m.Info.Timestamp.Unix(),
		FromMe: &fromMe, Group: &group,
	})
}
