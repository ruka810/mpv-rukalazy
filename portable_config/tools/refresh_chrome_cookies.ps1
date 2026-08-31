param()

# Retained only so an old manual shortcut fails safely.  Cookie refresh now
# uses the loaded Chrome extension and an in-memory local bridge; it never
# closes Chrome or reads/writes a Netscape cookies.txt file.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
@{
    success = $false
    message = '已停用：请使用 Chrome Cookie Bridge（内存模式）'
} | ConvertTo-Json -Compress
