package proxy

import "github.com/gin-gonic/gin"

type MediaProxy struct{ handler gin.HandlerFunc }

func NewMediaProxy(serviceURL string) *MediaProxy {
	return &MediaProxy{handler: New(serviceURL)}
}

func (p *MediaProxy) Handler() gin.HandlerFunc { return p.handler }
