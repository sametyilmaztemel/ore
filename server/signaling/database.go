package signaling

import (
	"database/sql"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// Database wraps the SQLite database operations.
type Database struct {
	db *sql.DB
}

// NewDatabase opens or creates the SQLite database.
func NewDatabase(dbPath string) (*Database, error) {
	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Enable WAL mode and foreign keys
	pragmas := []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA foreign_keys=ON",
	}
	for _, p := range pragmas {
		if _, err := db.Exec(p); err != nil {
			return nil, fmt.Errorf("failed to set pragma: %w", err)
		}
	}

	d := &Database{db: db}
	if err := d.createTables(); err != nil {
		return nil, fmt.Errorf("failed to create tables: %w", err)
	}

	return d, nil
}

func (d *Database) createTables() error {
	// Host whitelist table
	_, err := d.db.Exec(`
		CREATE TABLE IF NOT EXISTS device_whitelist (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			device_id TEXT NOT NULL UNIQUE,
			device_name TEXT,
			device_type TEXT DEFAULT 'ios',
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			last_seen TIMESTAMP,
			is_active BOOLEAN DEFAULT 1
		)
	`)
	if err != nil {
		return err
	}

	// Connection logs table
	_, err = d.db.Exec(`
		CREATE TABLE IF NOT EXISTS connection_logs (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			device_id TEXT NOT NULL,
			host_id TEXT,
			timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			duration INTEGER DEFAULT 0,
			ip_address TEXT,
			status TEXT DEFAULT 'connected',
			connection_type TEXT DEFAULT 'websocket',
			notes TEXT
		)
	`)
	if err != nil {
		return err
	}

	// Pairing codes table
	_, err = d.db.Exec(`
		CREATE TABLE IF NOT EXISTS pairing_codes (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			code TEXT NOT NULL UNIQUE,
			device_id TEXT NOT NULL,
			host_id TEXT NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			expires_at TIMESTAMP,
			is_used BOOLEAN DEFAULT 0
		)
	`)
	return err
}

// Close closes the database connection.
func (d *Database) Close() error {
	return d.db.Close()
}

// WhitelistDevice adds a device to the whitelist.
func (d *Database) WhitelistDevice(deviceID, deviceName, deviceType string) error {
	_, err := d.db.Exec(
		`INSERT OR REPLACE INTO device_whitelist (device_id, device_name, device_type, last_seen)
		 VALUES (?, ?, ?, CURRENT_TIMESTAMP)`,
		deviceID, deviceName, deviceType,
	)
	return err
}

// IsDeviceWhitelisted checks if a device is in the whitelist.
func (d *Database) IsDeviceWhitelisted(deviceID string) (bool, error) {
	var count int
	err := d.db.QueryRow(
		`SELECT COUNT(*) FROM device_whitelist WHERE device_id = ? AND is_active = 1`,
		deviceID,
	).Scan(&count)
	return count > 0, err
}

// ListWhitelistedDevices returns all whitelisted devices.
func (d *Database) ListWhitelistedDevices() ([]map[string]interface{}, error) {
	rows, err := d.db.Query(
		`SELECT device_id, device_name, device_type, created_at, last_seen, is_active
		 FROM device_whitelist ORDER BY last_seen DESC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []map[string]interface{}
	for rows.Next() {
		var deviceID, deviceName, deviceType string
		var createdAt, lastSeen time.Time
		var isActive bool
		var name, dtype sql.NullString

		err := rows.Scan(&deviceID, &name, &dtype, &createdAt, &lastSeen, &isActive)
		if err != nil {
			return nil, err
		}

		if name.Valid {
			deviceName = name.String
		}
		if dtype.Valid {
			deviceType = dtype.String
		}

		devices = append(devices, map[string]interface{}{
			"device_id":   deviceID,
			"device_name": deviceName,
			"device_type": deviceType,
			"created_at":  createdAt.Format(time.RFC3339),
			"last_seen":   lastSeen.Format(time.RFC3339),
			"is_active":   isActive,
		})
	}
	return devices, nil
}

// LogConnection logs a connection event.
func (d *Database) LogConnection(deviceID, hostID, status string) error {
	_, err := d.db.Exec(
		`INSERT INTO connection_logs (device_id, host_id, status, timestamp)
		 VALUES (?, ?, ?, CURRENT_TIMESTAMP)`,
		deviceID, hostID, status,
	)
	return err
}

// UpdateConnectionDuration updates the duration of a connection.
func (d *Database) UpdateConnectionDuration(deviceID string, duration int) error {
	_, err := d.db.Exec(
		`UPDATE connection_logs SET duration = ?
		 WHERE device_id = ? AND status = 'connected'
		 ORDER BY timestamp DESC LIMIT 1`,
		duration, deviceID,
	)
	return err
}

// GetRecentConnections returns recent connection logs.
func (d *Database) GetRecentConnections(limit int) ([]map[string]interface{}, error) {
	rows, err := d.db.Query(
		`SELECT device_id, host_id, timestamp, duration, status
		 FROM connection_logs ORDER BY timestamp DESC LIMIT ?`,
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var logs []map[string]interface{}
	for rows.Next() {
		var deviceID, hostID, status string
		var timestamp time.Time
		var duration int
		var hid sql.NullString

		err := rows.Scan(&deviceID, &hid, &timestamp, &duration, &status)
		if err != nil {
			return nil, err
		}

		if hid.Valid {
			hostID = hid.String
		}

		logs = append(logs, map[string]interface{}{
			"device_id": deviceID,
			"host_id":   hostID,
			"timestamp": timestamp.Format(time.RFC3339),
			"duration":  duration,
			"status":    status,
		})
	}
	return logs, nil
}
