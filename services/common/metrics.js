import * as prometheus from 'prom-client';

export function setupMetrics(serviceName) {
  // Create Prometheus metrics
  const httpRequestDurationMicroseconds = new prometheus.Histogram({
    name: 'http_request_duration_seconds',
    help: 'Duration of HTTP requests in seconds',
    labelNames: ['service', 'method', 'route', 'code'],
    buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5]
  });

  const httpRequestCounter = new prometheus.Counter({
    name: 'http_requests_total',
    help: 'Total number of HTTP requests',
    labelNames: ['service', 'method', 'route', 'code']
  });

  // Register metrics
  prometheus.collectDefaultMetrics({
    prefix: `${serviceName}_`,
    labels: { service: serviceName }
  });

  // Middleware for measuring request duration
  const metricsMiddleware = (req, res, next) => {
    const start = Date.now();
    res.on('finish', () => {
      const duration = (Date.now() - start) / 1000;
      httpRequestDurationMicroseconds
        .labels(serviceName, req.method, req.path, res.statusCode)
        .observe(duration);
      httpRequestCounter
        .labels(serviceName, req.method, req.path, res.statusCode)
        .inc();
    });
    next();
  };

  // Metrics endpoint handler
  const metricsHandler = async (req, res) => {
    res.set('Content-Type', prometheus.register.contentType);
    res.end(await prometheus.register.metrics());
  };

  return {
    metricsMiddleware,
    metricsHandler,
    register: prometheus.register
  };
}
