import { setupServiceApp } from '../common/service-setup.js';
import { createChildSpan, decorateSpan } from '../common/tracing.js';

const serviceName = 'echo-service';
const { app, tracer, port, setupGracefulShutdown } = setupServiceApp(serviceName);

// Echo endpoint
app.post('/echo', (req, res) => {
    const { span } = req;

    // Create a child span for payload processing
    const processSpan = createChildSpan(span, tracer, 'process-payload');
    const size = JSON.stringify(req.body).length;

    // Add tags and logs to span
    decorateSpan(
        processSpan,
        { 'request.size': size },
        {
            event: 'processing',
            message: `Processing payload of size ${size} bytes`
        }
    );

    processSpan.finish();

    res.json({
        message: "Echo service processed request",
        requestSize: size,
        timestamp: new Date().toISOString()
    });
});

// Start the server
const server = app.listen(port, () => {
    console.log(`${serviceName} listening on port ${port}`);
});

// Setup graceful shutdown
setupGracefulShutdown(server);
