param(
    [ValidateSet('image', 'video', 'video-mkv', 'subtitle-warning', 'container-warning')]
    [string]$Mode = 'image',
    [string]$SuggestedPath = '',
    [string]$Warning = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
