param(
    [ValidateSet('image', 'video', 'video-mkv', 'subtitle-warning', 'container-warning', 'scale')]
    [string]$Mode = 'image',
    [string]$SuggestedPath = '',
    [string]$Warning = '',
    [int]$DefaultScale = 1
)

# mpv reads subprocess stdout as UTF-8. Windows PowerShell otherwise inherits
# the launcher's console code page (often CP936), corrupting Chinese paths.
$captureUtf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $captureUtf8
$OutputEncoding = $captureUtf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($Mode -eq 'scale') {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Select output scale'
    $form.Size = New-Object System.Drawing.Size(300, 140)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    # 置顶显示，避免被 mpv 全屏/前台窗口挡住（否则对话框抢走键盘焦点却看不见）
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Output resolution:'
    $label.Location = New-Object System.Drawing.Point(15, 15)
    $label.AutoSize = $true

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Items.AddRange(@('1x (source resolution)', '2x', '3x', '4x'))
    if ($DefaultScale -ge 2 -and $DefaultScale -le 4) { $combo.SelectedIndex = $DefaultScale - 1 } else { $combo.SelectedIndex = 0 }
    $combo.Location = New-Object System.Drawing.Point(15, 40)
    $combo.Width = 240

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Location = New-Object System.Drawing.Point(100, 75)
    $ok.Width = 80
    $ok.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(190, 75)
    $cancel.Width = 80
    $cancel.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })

    $form.Controls.Add($label)
    $form.Controls.Add($combo)
    $form.Controls.Add($ok)
    $form.Controls.Add($cancel)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $text = $combo.SelectedItem.ToString()
        if ($text -match '^(\d+)x') { [Console]::Out.Write($matches[1]) }
    }
    exit
}

if ($Mode -eq 'subtitle-warning') {
    $message = "$Warning`n`nYes: choose MKV and keep all subtitle tracks.`nNo: export without incompatible subtitle tracks.`nCancel: stop exporting."
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Incompatible subtitle tracks',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    switch ($choice) {
        ([System.Windows.Forms.DialogResult]::Yes) { [Console]::Out.Write('mkv') }
        ([System.Windows.Forms.DialogResult]::No) { [Console]::Out.Write('omit') }
        default { [Console]::Out.Write('cancel') }
    }
    exit
}

if ($Mode -eq 'container-warning') {
    $message = "$Warning`n`nYes: choose MKV and keep original streams.`nNo: cancel exporting."
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Selected container is incompatible',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        [Console]::Out.Write('mkv')
    } else {
        [Console]::Out.Write('cancel')
    }
    exit
}

$dialog = New-Object System.Windows.Forms.SaveFileDialog
$dialog.OverwritePrompt = $true
$dialog.RestoreDirectory = $true
$dialog.AddExtension = $true
$dialog.Title = if ($Mode -like 'video*') { 'Export video clip' } else { 'Save original video frame' }

if ($SuggestedPath) {
    $directory = Split-Path -Parent $SuggestedPath
    if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) {
        $dialog.InitialDirectory = $directory
    }
    $dialog.FileName = Split-Path -Leaf $SuggestedPath
}

if ($Mode -eq 'video' -or $Mode -eq 'video-mkv') {
    if ($Mode -eq 'video-mkv') {
        $dialog.Filter = 'Matroska video (*.mkv)|*.mkv'
        $dialog.DefaultExt = 'mkv'
        if (-not $SuggestedPath) { $dialog.FileName = 'mpv-clip.mkv' }
    } else {
        $dialog.Filter = 'Matroska video (*.mkv)|*.mkv|MP4 video (*.mp4)|*.mp4|WebM video (*.webm)|*.webm|MOV video (*.mov)|*.mov'
        $dialog.FilterIndex = 1
        $dialog.DefaultExt = 'mkv'
        if (-not $SuggestedPath) { $dialog.FileName = 'mpv-clip.mkv' }
    }
} else {
    $dialog.Filter = 'PNG image (*.png)|*.png|JPEG image (*.jpg;*.jpeg)|*.jpg;*.jpeg|WebP image (*.webp)|*.webp'
    $dialog.FilterIndex = 1
    $dialog.DefaultExt = 'png'
    if (-not $SuggestedPath) { $dialog.FileName = 'mpv-frame.png' }
}

if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::Out.Write($dialog.FileName)
}
