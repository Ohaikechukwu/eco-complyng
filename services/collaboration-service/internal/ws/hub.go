package ws

import (
	"sync"

	"github.com/rs/zerolog/log"
)

type Hub struct {
	mu      sync.RWMutex
	rooms   map[string]map[*Client]bool
	join    chan *Client
	leave   chan *Client
	message chan *Message
}

type Message struct {
	RoomID  string
	Payload []byte
	Sender  *Client
}

func NewHub() *Hub {
	return &Hub{
		rooms:   make(map[string]map[*Client]bool),
		join:    make(chan *Client, 64),
		leave:   make(chan *Client, 64),
		message: make(chan *Message, 256),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case client := <-h.join:
			h.mu.Lock()
			if h.rooms[client.RoomID] == nil {
				h.rooms[client.RoomID] = make(map[*Client]bool)
			}
			h.rooms[client.RoomID][client] = true
			h.mu.Unlock()
			log.Info().Str("room", client.RoomID).Str("user", client.UserID).Msg("ws: client joined")

		case client := <-h.leave:
			if h.removeClient(client) {
				log.Info().Str("room", client.RoomID).Str("user", client.UserID).Msg("ws: client left")
			}

		case msg := <-h.message:
			h.mu.Lock()
			for client := range h.rooms[msg.RoomID] {
				if client == msg.Sender {
					continue
				}
				select {
				case client.send <- msg.Payload:
				default:
					h.removeClientLocked(client)
				}
			}
			h.mu.Unlock()
		}
	}
}

func (h *Hub) Join(c *Client)       { h.join <- c }
func (h *Hub) Leave(c *Client)      { h.leave <- c }
func (h *Hub) Broadcast(m *Message) { h.message <- m }

func (h *Hub) removeClient(client *Client) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.removeClientLocked(client)
}

func (h *Hub) removeClientLocked(client *Client) bool {
	room, ok := h.rooms[client.RoomID]
	if !ok {
		return false
	}
	if _, exists := room[client]; !exists {
		return false
	}

	delete(room, client)
	close(client.send)
	if len(room) == 0 {
		delete(h.rooms, client.RoomID)
	}

	return true
}
