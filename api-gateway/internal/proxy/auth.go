package proxy

import (
	"github.com/gin-gonic/gin"
)

type AuthProxy struct {
	handler gin.HandlerFunc
}

func NewAuthProxy(serviceURL string) *AuthProxy {
	return &AuthProxy{handler: New(serviceURL)}
}

func (p *AuthProxy) Handler() gin.HandlerFunc {
	return p.handler
}
