package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type NotificationClient struct {
	baseURL    string
	httpClient *http.Client
}

func NewNotificationClient(baseURL string) *NotificationClient {
	return &NotificationClient{
		baseURL:    baseURL,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

type sendEmailRequest struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
}

func (n *NotificationClient) SendInviteEmail(ctx context.Context, toEmail, name, orgName, role, tempPassword, loginURL string) error {
	body := fmt.Sprintf(`Hi %s,

You have been invited to join %s on EcoComply NG as a %s.

Your login details:
  Email:    %s
  Password: %s

Please log in at %s and change your password immediately after signing in.

This is an automated message from EcoComply NG.`, name, orgName, role, toEmail, tempPassword, loginURL)

	payload := sendEmailRequest{
		To:      toEmail,
		Subject: fmt.Sprintf("You've been invited to join %s on EcoComply NG", orgName),
		Body:    body,
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		n.baseURL+"/api/v1/notifications/email", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := n.httpClient.Do(req)
	if err != nil {
		// Don't fail the invite if notification service is down
		fmt.Printf("WARNING: notification service unreachable: %v\n", err)
		return nil
	}
	defer resp.Body.Close()
	return nil
}

func (n *NotificationClient) SendPasswordResetEmail(ctx context.Context, toEmail, name, resetURL string) error {
	body := fmt.Sprintf(`Hi %s,

We received a password reset request for your EcoComply NG account.

Use the link below to set a new password:
%s

If you did not request this, you can ignore this email.`, name, resetURL)

	payload := sendEmailRequest{
		To:      toEmail,
		Subject: "Reset your EcoComply NG password",
		Body:    body,
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		n.baseURL+"/api/v1/notifications/email", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := n.httpClient.Do(req)
	if err != nil {
		fmt.Printf("WARNING: notification service unreachable: %v\n", err)
		return nil
	}
	defer resp.Body.Close()
	return nil
}
