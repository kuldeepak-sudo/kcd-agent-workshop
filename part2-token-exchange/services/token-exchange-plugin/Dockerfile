# Tyk OSS gRPC coprocess plugin that hand-rolls RFC 8693-style token exchange
# (see plugin.py for why: Tyk's built-in tokenExchange middleware is Enterprise
# only; gRPC/rich plugins are a long-standing OSS gateway capability).
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5555 8081
ENTRYPOINT ["python3", "plugin.py"]
