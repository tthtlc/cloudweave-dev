FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY static/ ./static/

# Run as an unprivileged user; /app must stay writable for .flask_secret.
RUN useradd --create-home appuser && chown -R appuser:appuser /app
USER appuser

ENV PORT=5050
EXPOSE 5050

CMD ["python", "app.py"]
