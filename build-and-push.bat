@echo off
REM Build script for logstash-output-elasticsearch Docker image (Windows)

REM Configuration
if "%IMAGE_NAME%"=="" set IMAGE_NAME=logstash-custom-elasticsearch-output
if "%IMAGE_TAG%"=="" set IMAGE_TAG=8.4.0-custom
if "%LOGSTASH_VERSION%"=="" set LOGSTASH_VERSION=8.4.0
REM Set REGISTRY to your registry, e.g., "docker.io/username" or "your-registry.azurecr.io"
if "%REGISTRY%"=="" (
    set FULL_IMAGE_NAME=%IMAGE_NAME%:%IMAGE_TAG%
) else (
    set FULL_IMAGE_NAME=%REGISTRY%/%IMAGE_NAME%:%IMAGE_TAG%
)

echo ==========================================
echo Building Logstash Docker Image
echo ==========================================
echo Base Logstash Version: %LOGSTASH_VERSION%
echo Image Name: %FULL_IMAGE_NAME%
echo ==========================================

REM Build the Docker image
docker build --build-arg LOGSTASH_VERSION=%LOGSTASH_VERSION% -t %FULL_IMAGE_NAME% -f Dockerfile .

if %ERRORLEVEL% NEQ 0 (
    echo Build failed!
    exit /b %ERRORLEVEL%
)

echo.
echo ==========================================
echo Build Complete!
echo ==========================================
echo Image: %FULL_IMAGE_NAME%
echo.

REM Ask if user wants to push
if not "%REGISTRY%"=="" (
    set /p PUSH_CONFIRM="Do you want to push the image to %REGISTRY%? (y/n) "
    if /i "%PUSH_CONFIRM%"=="y" (
        echo Pushing image to registry...
        docker push %FULL_IMAGE_NAME%
        if %ERRORLEVEL% NEQ 0 (
            echo Push failed!
            exit /b %ERRORLEVEL%
        )
        echo Push complete!
    )
)

echo.
echo To use this image locally:
echo   docker run -it --rm %FULL_IMAGE_NAME% --version
echo.
echo To update your Kubernetes StatefulSet:
echo   kubectl set image statefulset/logstash-logstash logstash=%FULL_IMAGE_NAME% -n elastic-search
echo.
