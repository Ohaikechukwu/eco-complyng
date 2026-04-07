package proxy

import "github.com/gin-gonic/gin"

type NotificationProxy struct{ handler gin.HandlerFunc }

func NewNotificationProxy(serviceURL string) *NotificationProxy {
	return &NotificationProxy{handler: New(serviceURL)}
}

func (p *NotificationProxy) Handler() gin.HandlerFunc { return p.handler }
