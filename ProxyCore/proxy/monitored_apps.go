package proxy

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

type MonitoredApp struct {
	BundleID       string `json:"bundle_id"`
	Name           string `json:"name"`
	DecryptTraffic bool   `json:"decrypt_traffic"`
}

type MonitoredAppsManager struct {
	apps map[string]MonitoredApp
	mu   sync.RWMutex
	file string
}

func NewMonitoredAppsManager(configFile string) *MonitoredAppsManager {
	manager := &MonitoredAppsManager{
		apps: make(map[string]MonitoredApp),
		file: configFile,
	}
	_ = manager.loadFromFile()
	return manager
}

func (m *MonitoredAppsManager) loadFromFile() error {
	data, err := os.ReadFile(m.file)
	if err != nil {
		return err
	}
	var apps []MonitoredApp
	if err := json.Unmarshal(data, &apps); err != nil {
		return err
	}
	m.mu.Lock()
	for _, app := range apps {
		m.apps[app.BundleID] = app
	}
	m.mu.Unlock()
	return nil
}

func (m *MonitoredAppsManager) saveToFileLocked() error {
	apps := make([]MonitoredApp, 0, len(m.apps))
	for _, app := range m.apps {
		apps = append(apps, app)
	}
	data, err := json.MarshalIndent(apps, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(m.file, data)
}

func (m *MonitoredAppsManager) AddApp(app MonitoredApp) error {
	if app.BundleID == "" {
		return fmt.Errorf("bundle_id is required")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.apps[app.BundleID] = app
	return m.saveToFileLocked()
}

func (m *MonitoredAppsManager) RemoveApp(bundleID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.apps, bundleID)
	return m.saveToFileLocked()
}

func (m *MonitoredAppsManager) GetApp(bundleID string) (MonitoredApp, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	app, exists := m.apps[bundleID]
	return app, exists
}

func (m *MonitoredAppsManager) ListApps() []MonitoredApp {
	m.mu.RLock()
	defer m.mu.RUnlock()
	apps := make([]MonitoredApp, 0, len(m.apps))
	for _, app := range m.apps {
		apps = append(apps, app)
	}
	return apps
}
