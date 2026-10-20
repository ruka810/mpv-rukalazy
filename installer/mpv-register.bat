@echo off
setlocal

chcp 936

"%~dp0/../mpv.com" --config=no --register
if %errorlevel% neq 0 (
	echo ========================================
	echo ע��ʧ�ܡ�Ӧȷ�� mpv.com �� mpv.exe ���ϼ�Ŀ¼��
	echo ========================================
	pause
	exit /b %errorlevel%
)

chcp 936

echo ========================================
echo ע��ɹ���
echo �벻Ҫ��� mpv.exe ��λ�á�
echo �����ƶ����ļ���ֻ���������д��ļ���������ע�ᡣ
echo ========================================

pause
endlocal
