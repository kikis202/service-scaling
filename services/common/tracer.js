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
  opentracing.initGlobalTracer(tracer);

  return tracer;
}

export function createTracingMiddleware(tracer) {
  return (req, res, next) => {
    const wireCtx = tracer.extract(opentracing.FORMAT_HTTP_HEADERS, req.headers);
    const span = tracer.startSpan(`${req.method} ${req.path}`, {
      childOf: wireCtx
    });

    span.setTag(opentracing.Tags.HTTP_METHOD, req.method);
    span.setTag(opentracing.Tags.HTTP_URL, req.url);
    span.setTag(opentracing.Tags.SPAN_KIND, opentracing.Tags.SPAN_KIND_RPC_SERVER);

    // Store span in request object
    req.span = span;

    // Finish span on response finish
    const finishSpan = () => {
      if (res.statusCode >= 400) {
        span.setTag(opentracing.Tags.ERROR, true);
        span.setTag(opentracing.Tags.HTTP_STATUS_CODE, res.statusCode);
      }
      span.finish();
    };

    res.on('finish', finishSpan);
    res.on('close', finishSpan);

    next();
  };
}

// Helper to create child spans
export function createChildSpan(parentSpan, tracer, operationName) {
  return tracer.startSpan(operationName, {
    childOf: parentSpan
  });
}

// Helper to add tags and logs to spans
export function decorateSpan(span, tags = {}, logs = null) {
  Object.entries(tags).forEach(([key, value]) => {
    span.setTag(key, value);
  });

  if (logs) {
    span.log(logs);
  }

  return span;
}
