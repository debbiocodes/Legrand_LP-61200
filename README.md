# Legrand PDU Control Plugin for Q-SYS

This Q-SYS plugin provides control and monitoring capabilities for Legrand PDU devices using their JSON-RPC API.

## Features

- Individual outlet control (On/Off/Cycle)
- Outlet group control (On/Off/Cycle)
- Customizable names for outlets and groups
- Real-time monitoring of:
  - Outlet current (RMS)
  - Temperature
  - Humidity
- User-configurable settings for all connection parameters


## Configuration

The plugin requires the following configuration (all fields are user-editable):

### Connection Settings
- **IP Address**: The IP address of your Legrand PDU
- **Port**: The port number for the PDU's web interface (default: 443)
- **Username**: Admin username for the PDU (default: admin)
- **Password**: Admin password for the PDU (default: raritan)

### Device Configuration
- **Number of Outlets**: Number of outlets on your PDU (1-24)
- **Number of Outlet Groups**: Number of outlet groups configured (0-8)

### Naming Configuration
- **Outlet Names**: Custom name for each outlet (e.g., "Server 1", "Router", "Switch")
- **Group Names**: Custom name for each outlet group (e.g., "Network Equipment", "Servers", "Lighting")

All these settings can be modified directly in the Q-SYS Designer interface without editing the plugin files. The custom names will be displayed in the interface and used in all controls and indicators related to that outlet or group.

## Usage

### Outlet Control
- Toggle the "Power" button to turn an outlet On/Off
- Press the "Cycle" button to power cycle an outlet
- Current readings are displayed below each outlet's controls
- Each outlet displays its custom name for easy identification

### Outlet Group Control
- Toggle the "Power" button to turn all outlets in the group On/Off
- Press the "Cycle" button to power cycle all outlets in the group
- Each group displays its custom name for easy identification

### Monitoring
- Temperature and humidity readings are displayed in the status section
- Individual outlet current measurements are shown below each outlet

## Troubleshooting

If you experience connection issues:

1. Verify the PDU's IP address and port number are correct and accessible
2. Check that the username and password are correct
3. Ensure the PDU's firmware supports JSON-RPC API (should be compatible with most recent Legrand/Raritan PDUs)
4. Check the Q-SYS Designer's log for any error messages

## Support

For support, please contact your Legrand representative or visit the Q-SYS help desk. 