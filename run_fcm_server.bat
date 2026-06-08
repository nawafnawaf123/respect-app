@echo off
cd /d "%~dp0"

REM Force correct local service account path and avoid old cached env value.
set FIREBASE_PROJECT_ID=respect-app-dbc77
set FIREBASE_SERVICE_ACCOUNT=C:\keys\respect-app.json

py -m uvicorn fcm_v1_server:app --host 0.0.0.0 --port 8000 --reload
pause
