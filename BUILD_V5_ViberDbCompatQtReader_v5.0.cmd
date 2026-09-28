@echo off
setlocal EnableExtensions
rem V5-040 Fix 4 external build helper. Run only from an MSVC 2022 x64 developer shell.
rem Requires QT_ROOT_DIR pointing to Qt 6.10.3 win64_msvc2022_64.
if "%QT_ROOT_DIR%"=="" (
  echo ERROR: QT_ROOT_DIR is not set.
  exit /b 2
)
where cl.exe >nul 2>nul || (echo ERROR: cl.exe not found.& exit /b 3)
if not exist "%QT_ROOT_DIR%\include\QtCore" (echo ERROR: QtCore headers not found.& exit /b 4)
if not exist "%QT_ROOT_DIR%\include\QtSql" (echo ERROR: QtSql headers not found.& exit /b 5)
if not exist "%QT_ROOT_DIR%\lib\Qt6Core.lib" (echo ERROR: Qt6Core.lib not found.& exit /b 6)
if not exist "%QT_ROOT_DIR%\lib\Qt6Sql.lib" (echo ERROR: Qt6Sql.lib not found.& exit /b 7)

cl.exe /nologo /std:c++17 /EHsc /O2 /MD /DUNICODE /D_UNICODE /DQT_NO_DEBUG ^
  /I"%QT_ROOT_DIR%\include" /I"%QT_ROOT_DIR%\include\QtCore" /I"%QT_ROOT_DIR%\include\QtSql" ^
  V5_ViberDbCompatQtReader_v5.0.cpp ^
  /Fe:V5_ViberDbCompatQtReader_v5.0.exe ^
  /link /SUBSYSTEM:CONSOLE /LIBPATH:"%QT_ROOT_DIR%\lib" Qt6Core.lib Qt6Sql.lib
if errorlevel 1 exit /b %errorlevel%
if not exist V5_ViberDbCompatQtReader_v5.0.exe exit /b 8
exit /b 0
