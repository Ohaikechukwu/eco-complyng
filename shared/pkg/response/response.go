package response

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

type Response struct {
	Success bool        `json:"success"`
	Message string      `json:"message,omitempty"`
	Data    interface{} `json:"data,omitempty"`
	Error   string      `json:"error,omitempty"`
}

func OK(c *gin.Context, message string, data interface{}) {
	c.JSON(http.StatusOK, Response{Success: true, Message: message, Data: data})
}

func Created(c *gin.Context, message string, data interface{}) {
	c.JSON(http.StatusCreated, Response{Success: true, Message: message, Data: data})
}

func BadRequest(c *gin.Context, err string) {
	c.JSON(http.StatusBadRequest, Response{Success: false, Error: err})
}

func Unauthorized(c *gin.Context, err string) {
	c.JSON(http.StatusUnauthorized, Response{Success: false, Error: err})
}

func Forbidden(c *gin.Context, err string) {
	c.JSON(http.StatusForbidden, Response{Success: false, Error: err})
}

func NotFound(c *gin.Context, err string) {
	c.JSON(http.StatusNotFound, Response{Success: false, Error: err})
}

func InternalError(c *gin.Context, err string) {
	c.JSON(http.StatusInternalServerError, Response{Success: false, Error: err})
}
