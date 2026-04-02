class KaspaDatabaseDashboard {
    constructor() {
        this.updateInterval = 10000;
        this.retryInterval = 5000;
        this.apiTimeout = 30000;
        this.apiBase = this.resolveApiBase();
        this.elements = this.cacheElements();
        this.pollTimer = null;
        this.init();
    }

    cacheElements() {
        return {
            dbSizeValue: document.getElementById('dbSizeValue'),
            nodeStatusDot: document.getElementById('nodeStatusDot'),
            kaspadVersion: document.getElementById('kaspadVersion'),
            tableCountValue: document.getElementById('tableCountValue'),
            largestTableValue: document.getElementById('largestTableValue'),
            uptimeValue: document.getElementById('uptimeValue'),
            storageValue: document.getElementById('storageValue'),
            rowSummary: document.getElementById('rowSummary'),
            tableStatsBody: document.getElementById('tableStatsBody'),
            statusBadge: document.getElementById('statusBadge'),
            statusLabel: document.getElementById('statusLabel'),
            statusDot: document.getElementById('statusDot'),
            lastUpdated: document.getElementById('lastUpdated'),
        };
    }

    init() {
        this.fetchData();
    }

    async fetchData() {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), this.apiTimeout);
        try {
            const response = await fetch(this.buildApiUrl(`/api/status?t=${Date.now()}`), {
                signal: controller.signal,
            });
            clearTimeout(timeoutId);

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`API error ${response.status}: ${errorText}`);
            }

            const contentType = response.headers.get('content-type') || '';
            if (!contentType.includes('application/json')) {
                const errorText = await response.text();
                throw new Error(`Unexpected response: ${errorText}`);
            }

            const data = await response.json();
            this.render(data);
            this.updateStatus(true, 'Synced with API');
            this.scheduleNext(this.updateInterval);
        } catch (error) {
            clearTimeout(timeoutId);
            console.error(error);
            this.updateStatus(false);
            this.scheduleNext(this.retryInterval);
        }
    }

    resolveApiBase() {
        const params = new URLSearchParams(window.location.search);
        const origin = params.get('origin');
        const app = params.get('app');

        if (!origin || !app) {
            return '';
        }

        return `${window.location.origin}/?origin=${encodeURIComponent(origin)}&app=${encodeURIComponent(app)}&path=`;
    }

    buildApiUrl(path) {
        if (!this.apiBase) {
            return path;
        }

        return `${this.apiBase}${encodeURIComponent(path)}`;
    }

    scheduleNext(delayMs) {
        if (this.pollTimer) {
            clearTimeout(this.pollTimer);
        }
        this.pollTimer = setTimeout(() => this.fetchData(), delayMs);
    }

    render(payload) {
        const nodeStatus = payload.status || 'unknown';
        const image = payload.image || '—';
        const uptimeSeconds = Number(payload.uptimeSeconds ?? 0);
        const appDir = payload.appDir || '/app/data';
        const appDirSizeBytes = Number(payload.appDirSizeBytes ?? 0);
        const utxoIndexEnabled = payload.utxoIndexEnabled;
        const kaspadVersion = payload.kaspadVersion;
        const imageVersion = this.versionFromImage(image);

        this.elements.dbSizeValue.textContent = this.formatStatus(nodeStatus);
        if (this.elements.kaspadVersion) {
            const versionValue = kaspadVersion || imageVersion || '—';
            this.elements.kaspadVersion.textContent = versionValue;
        }
        this.elements.largestTableValue.textContent = this.formatImageName(image);
        if (this.elements.uptimeValue) {
            this.elements.uptimeValue.textContent = this.formatDuration(uptimeSeconds);
        }
        if (this.elements.storageValue) {
            this.elements.storageValue.textContent = this.formatBytes(appDirSizeBytes);
        }
        this.elements.rowSummary.textContent = [
            `--appdir=${appDir}`,
            '--yes',
            '--nologfiles',
            '--disable-upnp',
            utxoIndexEnabled ? '--utxoindex' : '--utxoindex (disabled)',
            '--rpclisten=0.0.0.0:16110',
            '--rpclisten-borsh=0.0.0.0:17110',
            '--rpclisten-json=0.0.0.0:18110',
        ]
            .filter(Boolean)
            .join('\n');

        this.populateTableStats(payload.logTail || [], this.elements.tableStatsBody);

        if (this.elements.lastUpdated) {
            if (payload.timestamp) {
                const updatedAt = new Date(payload.timestamp);
                this.elements.lastUpdated.textContent = Number.isNaN(updatedAt.getTime())
                    ? new Date().toLocaleString()
                    : updatedAt.toLocaleString();
            } else {
                this.elements.lastUpdated.textContent = new Date().toLocaleString();
            }
        }
    }

    versionFromImage(image) {
        if (!image || image === '—' || typeof image !== 'string') {
            return '';
        }
        const trimmed = image.trim();
        if (!trimmed) {
            return '';
        }
        const tag = trimmed.includes(':') ? trimmed.split(':').pop() : '';
        if (!tag || tag === 'latest') {
            return '';
        }
        return tag.startsWith('v') ? tag.slice(1) : tag;
    }

    formatImageName(image) {
        if (!image || image === '—' || typeof image !== 'string') {
            return '—';
        }
        const trimmed = image.trim();
        if (!trimmed) {
            return '—';
        }
        const withoutNamespace = trimmed.includes('/') ? trimmed.split('/').pop() || trimmed : trimmed;
        const normalized = withoutNamespace.replace('rusty-kaspad', 'rusty-kaspa');
        return `kaspanet/${normalized}`;
    }

    populateTableStats(stats, container) {
        if (!container) {
            return;
        }
        container.innerHTML = '';

        if (!Array.isArray(stats) || stats.length === 0) {
            container.innerHTML = `
                <tr>
                    <td colspan="2" class="py-6 text-center text-zinc-500">No log data available yet.</td>
                </tr>
            `;
            return;
        }

        stats.forEach((entry) => {
            const row = document.createElement('tr');
            row.innerHTML = `
                <td class="font-medium text-sm leading-tight">${entry.message}</td>
                <td>${this.formatLogTime(entry.timestamp)}</td>
            `;
            container.appendChild(row);
        });
    }

    updateStatus(healthy, label) {
        if (healthy) {
            this.elements.statusBadge.textContent = 'Connected';
            this.elements.statusBadge.style.borderColor = 'rgba(20, 184, 166, 0.6)';
            this.elements.statusBadge.style.backgroundColor = 'rgba(20, 184, 166, 0.15)';
            this.elements.statusLabel.textContent = label;
            this.elements.statusDot.className = 'w-3 h-3 rounded-full bg-teal-400 animate-pulse';
            if (this.elements.nodeStatusDot) {
                this.elements.nodeStatusDot.className = 'w-3 h-3 rounded-full bg-teal-400 animate-pulse';
            }
        } else {
            this.elements.statusBadge.textContent = 'Offline';
            this.elements.statusBadge.style.borderColor = 'rgba(248, 113, 113, 0.7)';
            this.elements.statusBadge.style.backgroundColor = 'rgba(248, 113, 113, 0.15)';
            this.elements.statusLabel.textContent = 'Waiting for API response';
            this.elements.statusDot.className = 'w-3 h-3 rounded-full bg-red-500 animate-pulse';
            this.elements.dbSizeValue.textContent = '--';
            if (this.elements.nodeStatusDot) {
                this.elements.nodeStatusDot.className = 'w-3 h-3 rounded-full bg-red-500 animate-pulse';
            }
            if (this.elements.kaspadVersion) {
                this.elements.kaspadVersion.textContent = '—';
            }
            if (this.elements.tableCountValue) {
                this.elements.tableCountValue.textContent = '--';
            }
            if (this.elements.uptimeValue) {
                this.elements.uptimeValue.textContent = '--';
            }
            if (this.elements.storageValue) {
                this.elements.storageValue.textContent = '--';
            }
            this.elements.rowSummary.textContent = 'Waiting for connection...';
            this.elements.largestTableValue.textContent = '—';
            this.elements.tableStatsBody.innerHTML = `
                <tr>
                    <td colspan="2" class="py-6 text-center text-zinc-500">Waiting for data...</td>
                </tr>
            `;
            if (this.elements.lastUpdated) {
                this.elements.lastUpdated.textContent = '--';
            }
        }
    }

    handleError() {
        this.updateStatus(false);
    }

    formatBytes(value) {
        const num = Number(value) || 0;
        if (num >= 1_000_000_000) {
            return `${(num / 1_000_000_000).toFixed(1)} GB`;
        }
        if (num >= 1_000_000) {
            return `${(num / 1_000_000).toFixed(1)} MB`;
        }
        if (num >= 1_000) {
            return `${(num / 1_000).toFixed(1)} KB`;
        }
        return `${num.toLocaleString()} B`;
    }

    formatNumber(value) {
        const num = Number(value) || 0;
        if (num >= 1_000_000) {
            return `${(num / 1_000_000).toFixed(1)}M`;
        }
        if (num >= 1_000) {
            return `${(num / 1_000).toFixed(1)}k`;
        }
        return num.toLocaleString();
    }


    formatDuration(seconds) {
        if (!Number.isFinite(seconds) || seconds <= 0) {
            return '--';
        }
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor((seconds % 86400) / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        if (days > 0) {
            return `${days}d ${hours}h`;
        }
        if (hours > 0) {
            return `${hours}h ${minutes}m`;
        }
        return `${minutes}m`;
    }

    formatLogTime(value) {
        if (!value) {
            return '--';
        }
        const parsed = new Date(value);
        if (Number.isNaN(parsed.getTime())) {
            return value;
        }
        return parsed.toLocaleString();
    }

    formatStatus(value) {
        if (!value) {
            return '--';
        }
        if (value.toLowerCase() === 'running') {
            return 'Running';
        }
        return value.charAt(0).toUpperCase() + value.slice(1);
    }
}

document.addEventListener('DOMContentLoaded', () => {
    new KaspaDatabaseDashboard();
});
