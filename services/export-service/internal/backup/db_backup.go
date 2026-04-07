package backup

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"
)

type DBBackup struct {
	Host     string
	Port     string
	User     string
	Password string
	DBName   string
	OutDir   string
}

// Run executes pg_dump and writes a compressed backup file.
// Returns the output file path.
func (b *DBBackup) Run(ctx context.Context) (string, error) {
	if err := os.MkdirAll(b.OutDir, 0755); err != nil {
		return "", fmt.Errorf("backup dir: %w", err)
	}

	filename := fmt.Sprintf("%s/backup_%s.sql.gz", b.OutDir, time.Now().Format("20060102_150405"))

	cmd := exec.CommandContext(ctx,
		"sh", "-c",
		fmt.Sprintf("PGPASSWORD=%s pg_dump -h %s -p %s -U %s %s | gzip > %s",
			b.Password, b.Host, b.Port, b.User, b.DBName, filename),
	)

	if output, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("pg_dump failed: %s — %w", string(output), err)
	}

	return filename, nil
}
