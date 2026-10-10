param([string]$Current = 'ask')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$zones = @(
  [pscustomobject]@{ Name = 'UTC'; Value = 'utc' },
  [pscustomobject]@{ Name = 'Pacific Time (Los Angeles)'; Value = 'America/Los_Angeles' },
  [pscustomobject]@{ Name = 'Mountain Time (Denver)'; Value = 'America/Denver' },
  [pscustomobject]@{ Name = 'Arizona Time (Phoenix, no daylight saving)'; Value = 'America/Phoenix' },
  [pscustomobject]@{ Name = 'Central Time (Chicago)'; Value = 'America/Chicago' },
  [pscustomobject]@{ Name = 'Eastern Time (New York)'; Value = 'America/New_York' },
  [pscustomobject]@{ Name = 'Alaska Time (Anchorage)'; Value = 'America/Anchorage' },
  [pscustomobject]@{ Name = 'Hawaii Time (Honolulu)'; Value = 'Pacific/Honolulu' },
  [pscustomobject]@{ Name = 'United Kingdom (London)'; Value = 'Europe/London' },
  [pscustomobject]@{ Name = 'Central European Time (Paris)'; Value = 'Europe/Paris' }
)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Marble Collector – Log Time Zone'
$form.Size = New-Object System.Drawing.Size(460, 195)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$label = New-Object System.Windows.Forms.Label
$label.Text = 'What time zone were these robot log timestamps taken in?'
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(18, 20)
$form.Controls.Add($label)

$note = New-Object System.Windows.Forms.Label
$note.Text = 'Choose the zone used in the akit_ filename, not necessarily the pit laptop zone.'
$note.AutoSize = $true
$note.Location = New-Object System.Drawing.Point(18, 45)
$form.Controls.Add($note)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.DropDownStyle = 'DropDownList'
$combo.Location = New-Object System.Drawing.Point(18, 75)
$combo.Size = New-Object System.Drawing.Size(408, 25)
$combo.DisplayMember = 'Name'
$combo.ValueMember = 'Value'
[void]$combo.Items.AddRange($zones)
$selected = $zones | Where-Object { $_.Value -eq $Current } | Select-Object -First 1
$combo.SelectedItem = if ($selected) { $selected } else { $zones[0] }
$form.Controls.Add($combo)

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Location = New-Object System.Drawing.Point(270, 115)
$save.Add_Click({ $form.Tag = $combo.SelectedItem.Value; $form.Close() })
$form.Controls.Add($save)

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.Location = New-Object System.Drawing.Point(350, 115)
$cancel.Add_Click({ $form.Tag = ''; $form.Close() })
$form.Controls.Add($cancel)

[void]$form.ShowDialog()
Write-Output $form.Tag
