/**
 * Index Generator - Creates searchable index files for GitHub
 */

interface ScanSummary {
  date: string;
  scanCount: number;
  uniqueRadios: number;
  uniqueNodes: number;
  minTimestamp: number;
  maxTimestamp: number;
  batchFiles: string[];
}

/**
 * Generate daily index CSV for easy filtering
 */
export function generateDailyIndexCSV(summaries: ScanSummary[]): string {
  const headers = [
    'date',
    'scan_count',
    'unique_radios',
    'unique_nodes',
    'first_scan_utc',
    'last_scan_utc',
    'csv_files',
    'json_files'
  ];
  
  const rows = [headers.join(',')];
  
  for (const summary of summaries) {
    const csvFiles = summary.batchFiles.filter(f => f.endsWith('.csv')).length;
    const jsonFiles = summary.batchFiles.filter(f => f.endsWith('.json')).length;
    
    rows.push([
      summary.date,
      summary.scanCount.toString(),
      summary.uniqueRadios.toString(),
      summary.uniqueNodes.toString(),
      new Date(summary.minTimestamp).toISOString(),
      new Date(summary.maxTimestamp).toISOString(),
      csvFiles.toString(),
      jsonFiles.toString()
    ].join(','));
  }
  
  return rows.join('\n');
}

/**
 * Generate README with filtering examples
 */
export function generateDataReadme(summaries: ScanSummary[]): string {
  const totalScans = summaries.reduce((sum, s) => sum + s.scanCount, 0);
  const allRadios = new Set<string>();
  const allNodes = new Set<string>();
  
  // Note: This is a simplified version - full implementation would track unique IDs
  const totalRadios = summaries.reduce((sum, s) => sum + s.uniqueRadios, 0);
  const totalNodes = summaries.reduce((sum, s) => sum + s.uniqueNodes, 0);
  
  const earliestDate = summaries.length > 0 ? summaries[0].date : 'N/A';
  const latestDate = summaries.length > 0 ? summaries[summaries.length - 1].date : 'N/A';
  
  return `# Mesh Data - Searchable CSV Dataset

Public dataset of MeshCore network scans collected via [mesh-utility-tracker](https://github.com/just-stuff-tm/mesh-utility-tracker).

## Quick Stats

- **Total Scans:** ${totalScans.toLocaleString()}
- **Unique Radios:** ~${totalRadios.toLocaleString()}
- **Unique Nodes:** ~${totalNodes.toLocaleString()}
- **Date Range:** ${earliestDate} to ${latestDate}
- **Last Updated:** ${new Date().toISOString()}

## Data Format

### CSV Files (Recommended for Analysis)

Each \`batch-*.csv\` file contains scan records with these columns:

| Column | Description | Example |
|--------|-------------|---------|
| \`radioId\` | Scanner's node ID | \`!abcd1234\` |
| \`timestamp\` | Unix timestamp (ms) | \`1705334400000\` |
| \`datetime_utc\` | ISO 8601 timestamp | \`2024-01-15T10:00:00.000Z\` |
| \`latitude\` | Latitude (decimal) | \`37.774900\` |
| \`longitude\` | Longitude (decimal) | \`-122.419400\` |
| \`altitude\` | Altitude in meters | \`50.0\` |
| \`nodeId\` | Detected node ID | \`!def45678\` |
| \`rssi\` | Signal strength (dBm) | \`-85\` |
| \`snr\` | Signal-to-noise ratio (dB) | \`8.5\` |

### JSON Files (For API Integration)

Same data in JSON array format for programmatic access.

## Searching Data in GitHub

GitHub's CSV viewer makes data exploration easy:

### 1. Browse by Date
Navigate to \`scans/YYYY-MM-DD/\` folders to find specific dates.

### 2. View CSV in Browser
Click any \`.csv\` file - GitHub will render it as a searchable table.

### 3. Filter Columns
Click column headers to sort or use GitHub's filter box.

### 4. Search Specific Radio IDs
Use GitHub search:
\`\`\`
!abcd1234 path:scans/ language:CSV
\`\`\`

### 5. Search by Signal Strength
\`\`\`
rssi:-5 path:scans/ language:CSV
\`\`\`

### 6. Search by Location (Approximate)
\`\`\`
37.77 path:scans/2024-01-15/ language:CSV
\`\`\`

## Download Filtered Data

### Method 1: GitHub Web Interface
1. Navigate to \`scans/YYYY-MM-DD/\`
2. Click \`batch-*.csv\` file
3. Click "Raw" button
4. Save file (Ctrl+S / Cmd+S)

### Method 2: GitHub CLI
\`\`\`bash
# Download specific day
gh repo clone just-stuff-tm/mesh-data
cd mesh-data/scans/2024-01-15
cat *.csv > combined-2024-01-15.csv

# Filter by radio ID
grep "!abcd1234" scans/**/*.csv > my-scans.csv

# Filter by date range
find scans/ -name "*.csv" -newer scans/2024-01-01 -exec cat {} \\; > jan-scans.csv
\`\`\`

### Method 3: Python Script
\`\`\`python
import pandas as pd
import glob

# Load all CSVs
files = glob.glob('scans/**/*.csv', recursive=True)
dfs = [pd.read_csv(f) for f in files]
all_data = pd.concat(dfs, ignore_index=True)

# Filter by radio ID
my_scans = all_data[all_data['radioId'] == '!abcd1234']

# Filter by signal strength
strong_signals = all_data[all_data['rssi'] > -80]

# Filter by date range
all_data['datetime'] = pd.to_datetime(all_data['datetime_utc'])
jan_scans = all_data[all_data['datetime'].dt.month == 1]

# Export filtered data
my_scans.to_csv('filtered-output.csv', index=False)
\`\`\`

### Method 4: Command Line (grep)
\`\`\`bash
# Find all scans from a radio
grep "!abcd1234" scans/**/*.csv

# Find strong signals (rssi > -70)
awk -F',' '$8 > -70' scans/**/*.csv

# Count scans per day
wc -l scans/*/*.csv
\`\`\`

## Advanced Filtering Examples

### Find Dead-Zone Rows
\`\`\`bash
# Rows where no repeater node was discovered
awk -F',' '$8 == ""' scans/**/*.csv
\`\`\`

### Geographic Bounding Box
\`\`\`python
# San Francisco area
sf_scans = all_data[
    (all_data['latitude'] >= 37.7) & (all_data['latitude'] <= 37.8) &
    (all_data['longitude'] >= -122.5) & (all_data['longitude'] <= -122.4)
]
\`\`\`

### Signal Quality Analysis
\`\`\`python
# Group by node, calculate average RSSI
node_quality = all_data.groupby('nodeId')['rssi'].agg(['mean', 'count'])
best_nodes = node_quality[node_quality['count'] > 10].sort_values('mean', ascending=False)
\`\`\`

### Time-Based Analysis
\`\`\`python
# Scans per hour
all_data['hour'] = pd.to_datetime(all_data['datetime_utc']).dt.hour
hourly = all_data.groupby('hour').size()
\`\`\`

## Data Quality Notes

- **Direct scans only:** Data comes from direct discovery scans (no mesh routing metrics stored)
- **Missing altitude:** Not all scans include altitude data
- **Duplicate detection:** Scanner may report same node multiple times per location
- **Timestamp precision:** Millisecond precision, UTC timezone

## Privacy & Deletion

- All data is public and anonymized
- Radio IDs are MeshCore public node identifiers
- Users can delete data from the app Settings ("Delete My Data")
- Deletion is ownership-verified using a radio-signed challenge
- Deletion records stored in \`deletions/\` folder

## Index Files

- [\`index.csv\`](index.csv) - Daily summary statistics
- Each date folder has its own README with stats

## Contributing

Data is automatically collected from mesh-utility-tracker users who opt-in.

To contribute:
1. Visit [mesh-utility-tracker](https://mesh-utility.org/)
2. Connect your MeshCore device
3. Enable "Share scan data" in Settings
4. Scans upload automatically

## API Access

For programmatic access, use JSON files or the worker API:

\`\`\`bash
# Get available days
curl https://mesh-utility-worker.workers.dev/history

# Get specific day (NDJSON format)
curl https://mesh-utility-worker.workers.dev/history/2024-01-15.ndjson

# Get as CSV (via GitHub Raw)
curl https://raw.githubusercontent.com/just-stuff-tm/mesh-data/main/scans/2024-01-15/batch-1705334400000.csv
\`\`\`

## License

CC0 1.0 Universal - Public Domain

## Support

- Issues: [mesh-utility-tracker/issues](https://github.com/just-stuff-tm/mesh-utility-tracker/issues)
- Data deletion: from app Settings ("Delete My Data")
`;
}
