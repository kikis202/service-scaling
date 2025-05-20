import { setupServiceApp } from '../common/service-setup.js';
import { createChildSpan, decorateSpan } from '../common/tracing.js';

const serviceName = 'ioService';
const { app, tracer, port, setupGracefulShutdown } = setupServiceApp(serviceName);

async function simulateIO(durationMs, failureRate = 0, span = null) {
    const opSpan = span ? createChildSpan(span, tracer, `io-operation-${durationMs}ms`) : null;

    return new Promise((resolve, reject) => {
        setTimeout(() => {
            // Simulate random failures
            if (Math.random() < failureRate) {
                if (opSpan) {
                    decorateSpan(
                        opSpan,
                        { 'error': true },
                        { event: 'error', message: 'Simulated IO failure' }
                    );
                    opSpan.finish();
                }
                reject(new Error('Simulated IO failure'));
            } else {
                if (opSpan) {
                    decorateSpan(
                        opSpan,
                        { 'duration': durationMs },
                        { event: 'complete', message: `Completed IO operation (${durationMs}ms)` }
                    );
                    opSpan.finish();
                }
                resolve({
                    durationMs,
                    data: `Sample data for operation at ${new Date().toISOString()}`
                });
            }
        }, durationMs);
    });
}

app.post('/simulate-io', async (req, res) => {
    const { span } = req;
    const processSpan = createChildSpan(span, tracer, 'simulated-io');

    const {
        pattern = 'single',        // single, sequential, parallel, random
        operations = 5,            // Number of operations
        baseDuration = 100,        // Base duration in ms
        variability = 0.75,         // Random variability (0-1)
        failureRate = 0.05         // Probability of operation failure (0-1)
    } = req.body;

    try {
        let results = [];
        switch (pattern) {
            case 'single':
                results = [await simulateIO(baseDuration, failureRate, processSpan)];
                break;

            case 'sequential':
                for (let i = 0; i < operations; i++) {
                    const duration = baseDuration * (1 + (Math.random() * variability - variability / 2));
                    const opSpan = createChildSpan(processSpan, tracer, `sequential-op-${i + 1}`);

                    try {
                        const result = await simulateIO(duration, failureRate, opSpan);
                        results.push(result);
                    } catch (error) {
                        results.push({ error: error.message, index: i });
                    } finally {
                        opSpan.finish();
                    }
                }
                break;

            case 'parallel':
                const parallelOps = [];
                for (let i = 0; i < operations; i++) {
                    const duration = baseDuration * (1 + (Math.random() * variability - variability / 2));
                    const opSpan = createChildSpan(processSpan, tracer, `parallel-op-${i + 1}`);

                    parallelOps.push(
                        simulateIO(duration, failureRate, opSpan)
                            .then(result => {
                                return result;
                            })
                            .catch(error => {
                                return { error: error.message, index: i };
                            })
                            .finally(() => {
                                opSpan.finish();
                            })
                    );
                }
                results = await Promise.all(parallelOps);
                break;
            default:
                throw new Error(`Unknown pattern: ${pattern}`);
        }


        decorateSpan(
            processSpan,
            {
                'operation.pattern': pattern,
                'operation.count': operations,
            },
            {
                event: 'io-simulation-complete',
                message: `Completed ${operations} simulated IO operations with ${pattern} pattern`
            }
        );

        res.json({
            message: `IO service processed simulated IO operations`,
            pattern,
            operations: operations,
            results,
        });
    } catch (error) {
        decorateSpan(
            processSpan,
            { 'error': true },
            { event: 'error', message: error.message }
        );

        res.status(500).json({
            error: "Simulated IO failed",
            message: error.message
        });
    } finally {
        processSpan.finish();
    }
});

// Server startup
const server = app.listen(port, () => {
    console.log(`${serviceName} listening on port ${port}`);
});

// Setup graceful shutdown
setupGracefulShutdown(server);
