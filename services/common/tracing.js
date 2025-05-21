import jaeger from 'jaeger-client';
import opentracing from 'opentracing';

export function initTracer(serviceName) {
  const config = {
    serviceName,
    sampler: {
      type: 'const',
      param: 1,
    },
    reporter: {
      logSpans: true,
      collectorEndpoint: process.env.JAEGER_COLLECTOR_ENDPOINT || 'http://jaeger-my-jaeger-collector.monitoring:14268/api/traces',
    },
  };

  const options = {
    logger: {
      info: (msg) => console.log('INFO ', msg),
      error: (msg) => console.error('ERROR', msg),
    },
  };

  const tracer = jaeger.initTracerFromEnv(config, options);

  const b3Propagator = new jaeger.ZipkinB3TextMapCodec({ urlEncoding: true });
  tracer.registerInjector(opentracing.FORMAT_HTTP_HEADERS, b3Propagator);
  tracer.registerExtractor(opentracing.FORMAT_HTTP_HEADERS, b3Propagator);

  opentracing.initGlobalTracer(tracer);
  return tracer;
}

export function createTracingMiddleware(tracer) {
  return (req, res, next) => {
    try {
      // Skip health checks
      if (req.path === '/health' || req.path === '/healthz') {
        next();
        return;
      }

      console.log('Trace headers received:', JSON.stringify(req.headers));

      // Extract trace context
      let parentSpanContext = null;
      try {
        parentSpanContext = tracer.extract(opentracing.FORMAT_HTTP_HEADERS, req.headers);
        console.log('Trace context extracted:', parentSpanContext ? 'Valid context' : 'No context');
      } catch (e) {
        console.log('Error extracting trace context:', e.message);
      }

      // Create span
      const span = tracer.startSpan(`${req.method} ${req.path}`, {
        childOf: parentSpanContext || undefined
      });

      try {
        const ctx = span.context();
        console.log('Span created:', {
          traceId: ctx._traceId.toString('hex'),
          spanId: ctx._spanId.toString('hex'),
          parentId: ctx._parentId ? ctx._parentId.toString('hex') : 'none'
        });
      } catch (e) {
        console.log('Error logging span details:', e.message);
      }

      // Add standard tags
      span.setTag(opentracing.Tags.HTTP_METHOD, req.method);
      span.setTag(opentracing.Tags.HTTP_URL, req.url);
      span.setTag(opentracing.Tags.SPAN_KIND, opentracing.Tags.SPAN_KIND_RPC_SERVER);

      // Store span in request object
      req.span = span;

      let spanFinished = false;
      const finishSpan = () => {
        if (!spanFinished) {
          spanFinished = true;
          if (res.statusCode >= 400) {
            span.setTag(opentracing.Tags.ERROR, true);
            span.setTag(opentracing.Tags.HTTP_STATUS_CODE, res.statusCode);
          }
          span.finish();
        }
      };

      res.on('finish', finishSpan);
      res.on('close', finishSpan);
    } catch (err) {
      console.error('Error in tracing middleware:', err);
    }

    next();
  };
}

// Helper functions remain the same
export function createChildSpan(parentSpan, tracer, operationName) {
  return tracer.startSpan(operationName, {
    childOf: parentSpan
  });
}

export function decorateSpan(span, tags = {}, logs = null) {
  Object.entries(tags).forEach(([key, value]) => {
    span.setTag(key, value);
  });

  if (logs) {
    span.log(logs);
  }

  return span;
}
