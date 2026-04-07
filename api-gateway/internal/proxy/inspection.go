package proxy

import "github.com/gin-gonic/gin"

type InspectionProxy struct{ handler gin.HandlerFunc }

func NewInspectionProxy(serviceURL string) *InspectionProxy {
	return &InspectionProxy{handler: New(serviceURL)}
}

func (p *InspectionProxy) Handler() gin.HandlerFunc { return p.handler }
