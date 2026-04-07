package domain

import "errors"

var (
	ErrNotFound     = errors.New("record not found")
	ErrInvalidInput = errors.New("invalid input")
)
