import { initTracer, createTracingMiddleware } from './tracing.js';
import { setupMetrics } from './metrics.js';
import express from 'express';

export function setupServiceApp(serviceName, port = 3000) {
  const app = express();

  // Initialize tracer
  const tracer = initTracer(serviceName);

  // Setup metrics
  const { metricsMiddleware, metricsHandler } = setupMetrics(serviceName);

  // Create tracing middleware
  const tracingMiddleware = createTracingMiddleware(tracer);

  // Apply middleware
  app.use(tracingMiddleware);
  app.use(metricsMiddleware);
  app.use(express.json({ limit: '10mb' }));

  // Add health check endpoint
  app.get('/health', (req, res) => {
    res.status(200).send('OK');
  });

  // Add metrics endpoint
  app.get('/metrics', metricsHandler);

  // Graceful shutdown helper
  const setupGracefulShutdown = (server) => {
    process.on('SIGTERM', () => {
      console.log('SIGTERM signal received: closing HTTP server');
      server.close(() => {
        console.log('HTTP server closed');
        tracer.close(() => {
          console.log('Tracer closed');
          process.exit(0);
        });
      });
    });
  };

  return {
    app,
    tracer,
    port,
    serviceName,
    setupGracefulShutdown
  };
}
