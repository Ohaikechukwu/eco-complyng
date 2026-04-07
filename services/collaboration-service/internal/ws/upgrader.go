package ws

import (
	"net/http"

	sharedcors "github.com/ecocomply/shared/pkg/cors"
	"github.com/gorilla/websocket"
)

var Upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true
		}
		return sharedcors.AllowOrigin(origin)
	},
}
