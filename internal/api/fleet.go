package api

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"
)

// FleetDevice represents a device's last known state.
type FleetDevice struct {
	Device        string          `json:"device"`
	TailscaleIP   string          `json:"tailscaleIp"`
	LocalIP       string          `json:"localIp"`
	CPUTemp       int             `json:"cpuTemp"`
	UptimeS       int             `json:"uptimeS"`
	DiskPct       int             `json:"diskPct"`
	StreamActive  bool            `json:"streamActive"`
	StreamEnabled bool            `json:"streamEnabled"`
	BootMode      string          `json:"bootMode"`
	Starlink      StarlinkStats   `json:"starlink"`
	LastSeen      time.Time       `json:"lastSeen"`
}

// StarlinkStats holds Starlink dish connectivity info.
type StarlinkStats struct {
	Reachable   bool    `json:"reachable"`
	LatencyMs   float64 `json:"latencyMs"`
	DownlinkMbps float64 `json:"downlinkMbps"`
	UplinkMbps  float64 `json:"uplinkMbps"`
	Obstructed  bool    `json:"obstructed"`
	UptimeS     int     `json:"uptimeS"`
}

// FleetStore is a thread-safe in-memory store for fleet device state.
type FleetStore struct {
	mu      sync.RWMutex
	devices map[string]*FleetDevice
}

// NewFleetStore creates a new fleet store.
func NewFleetStore() *FleetStore {
	return &FleetStore{
		devices: make(map[string]*FleetDevice),
	}
}

// Update stores or updates a device heartbeat.
func (fs *FleetStore) Update(dev FleetDevice) {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	dev.LastSeen = time.Now()
	fs.devices[dev.Device] = &dev
}

// All returns all known devices.
func (fs *FleetStore) All() []FleetDevice {
	fs.mu.RLock()
	defer fs.mu.RUnlock()
	out := make([]FleetDevice, 0, len(fs.devices))
	for _, d := range fs.devices {
		out = append(out, *d)
	}
	return out
}

// fleetHeartbeat handles POST /api/fleet/heartbeat
func (h *Handler) fleetHeartbeat(w http.ResponseWriter, r *http.Request) {
	var dev FleetDevice
	if err := json.NewDecoder(r.Body).Decode(&dev); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if dev.Device == "" {
		http.Error(w, "device name required", http.StatusBadRequest)
		return
	}
	h.fleet.Update(dev)
	log.Printf("[fleet] heartbeat: %s temp=%d°C stream=%v disk=%d%% starlink=%v",
		dev.Device, dev.CPUTemp, dev.StreamActive, dev.DiskPct, dev.Starlink.Reachable)
	w.WriteHeader(http.StatusOK)
}

// fleetStatus handles GET /api/fleet/status
func (h *Handler) fleetStatus(w http.ResponseWriter, r *http.Request) {
	devices := h.fleet.All()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(devices)
}
