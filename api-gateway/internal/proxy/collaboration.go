package proxy

import "github.com/gin-gonic/gin"

type CollaborationProxy struct{ handler gin.HandlerFunc }

func NewCollaborationProxy(serviceURL string) *CollaborationProxy {
	return &CollaborationProxy{handler: New(serviceURL)}
}

func (p *CollaborationProxy) Handler() gin.HandlerFunc { return p.handler }
