FROM python:3.12-slim-trixie

# trixie
# openjdk-21-jre-headless достаточно для keytool
RUN apt-get update && apt-get install -y \
    supervisor \
    openjdk-21-jdk-headless \
    build-essential \
    librdkafka-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY ./supervisord.conf /etc/supervisord.conf

WORKDIR /app
RUN pip install --no-cache-dir --upgrade pip setuptools wheel
COPY ./app/ /app/
RUN pip install --no-cache-dir -r requirements.txt

# see docker-compose stdin_open: true, tty: true
# CMD ["bash"]

ENTRYPOINT ["supervisord", "-c", "/etc/supervisord.conf"]
