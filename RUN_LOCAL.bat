@echo off
cd /d %~dp0

python --version >nul 2>&1
IF ERRORLEVEL 1 (
  echo Python n'est pas installe. Installe Python 3.11+ puis relance.
  pause
  exit /b 1
)

python -m pip install -r requirements.txt
python run_pipeline.py --full
python -m streamlit run app/Home.py
