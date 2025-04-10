package proxy

import (
	"encoding/json"
	"io/ioutil"
	"sync"
)

type MonitoredApp struct {
	BundleID      string `json:"bundle_id"`
	Name          string `json:"name"`
	DecryptTraffic bool  `json:"decrypt_traffic"`
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
	manager.loadFromFile()
	return manager
}

func (m *MonitoredAppsManager) loadFromFile() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	data, err := ioutil.ReadFile(m.file)
	if err != nil {
		return err
	}

	var apps []MonitoredApp
	if err := json.Unmarshal(data, &apps); err != nil {
		return err
	}

	for _, app := range apps {
		m.apps[app.BundleID] = app
	}
	return nil
}

func (m *MonitoredAppsManager) saveToFile() error {
	m.mu.RLock()
	apps := make([]MonitoredApp, 0, len(m.apps))
	for _, app := range m.apps {
		apps = append(apps, app)
	}
	m.mu.RUnlock()

	data, err := json.MarshalIndent(apps, "", "  ")
	if err != nil {
		return err
	}

	return ioutil.WriteFile(m.file, data, 0644)
}

func (m *MonitoredAppsManager) AddApp(app MonitoredApp) error {
	m.mu.Lock()
	m.apps[app.BundleID] = app
	m.mu.Unlock()
	return m.saveToFile()
}

func (m *MonitoredAppsManager) RemoveApp(bundleID string) error {
	m.mu.Lock()
	delete(m.apps, bundleID)
	m.mu.Unlock()
	return m.saveToFile()
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
