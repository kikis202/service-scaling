import { setupServiceApp } from '../common/service-setup.js';
import { createChildSpan, decorateSpan } from '../common/tracing.js';

const serviceName = 'cpuService';
const { app, tracer, port, setupGracefulShutdown } = setupServiceApp(serviceName);

function fibonacci(n, parentSpan = null) {
    // Create span for this specific calculation if parent span is provided
    const fibSpan = parentSpan ?
        createChildSpan(parentSpan, tracer, `fibonacci-${n}`) :
        null;

    let result;

    // Base cases
    if (n <= 1) {
        result = n;
    } else {
        result = fibonacci(n - 1) + fibonacci(n - 2);
    }

    // Finish span if created
    if (fibSpan) {
        decorateSpan(
            fibSpan,
            { 'fibonacci.n': n, 'fibonacci.result': result },
            { event: 'calculation', message: `Calculated fibonacci(${n}) = ${result}` }
        );
        fibSpan.finish();
    }

    return result;
}

// Calculate Fibonacci with tracing
function tracedFibonacci(n, parentSpan) {
    // Create spans only at certain checkpoints to avoid excessive spans
    const checkpoints = [];

    // Generate checkpoints based on size of n
    if (n > 30) {
        // For larger numbers, create fewer spans to avoid overwhelming tracing
        for (let i = n; i > n - 5; i -= 1) {
            checkpoints.push(i);
        }
    } else if (n > 20) {
        for (let i = n; i > 0; i -= 5) {
            checkpoints.push(i);
        }
    } else {
        for (let i = n; i > 0; i -= 2) {
            checkpoints.push(i);
        }
    }

    // Wrapper function to add spans at checkpoints
    function fibWithCheckpoints(k) {
        if (checkpoints.includes(k)) {
            const checkpointSpan = createChildSpan(parentSpan, tracer, `fibonacci-checkpoint-${k}`);

            const result = fibonacci(k);

            decorateSpan(
                checkpointSpan,
                {
                    'checkpoint.n': k,
                    'checkpoint.result': result,
                },
                {
                    event: 'checkpoint-calculation',
                    message: `Checkpoint fibonacci(${k})`
                }
            );

            checkpointSpan.finish();
            return result;
        } else {
            // Regular fibonacci for non-checkpoint numbers
            if (k <= 1) return k;
            return fibWithCheckpoints(k - 1) + fibWithCheckpoints(k - 2);
        }
    }

    return fibWithCheckpoints(n);
}

app.post('/fibonacci', (req, res) => {
    const { span } = req;
    const processSpan = createChildSpan(span, tracer, 'fibonacci-sequence-generation');

    const { n = 30 } = req.body;

    // Add validation
    const num = parseInt(n);
    if (isNaN(num) || num < 0) {
        res.status(400).json({ error: 'Please provide a valid non-negative integer' });
        processSpan.finish();
        return;
    }

    // Limit the input size to prevent server overload
    if (num > 40) {
        res.status(400).json({
            error: 'Input too large. Please use a value ≤ 40 to prevent timeout',
            message: 'Note: Fibonacci calculation complexity grows exponentially'
        });
        processSpan.finish();
        return;
    }

    try {
        // Calculate Fibonacci with traced checkpoints
        const result = tracedFibonacci(num, processSpan);

        decorateSpan(
            processSpan,
            {
                'operation.input': num,
                'operation.result': result,
            },
            {
                event: 'processing',
                message: `Calculated Fibonacci(${num}) = ${result}`
            }
        );

        res.json({
            message: "CPU service processed Fibonacci calculation",
            input: num,
            result: result,
        });
    } catch (error) {
        decorateSpan(
            processSpan,
            { 'error': true },
            { event: 'error', message: error.message }
        );

        res.status(500).json({
            error: "Calculation failed",
            message: error.message
        });
    } finally {
        processSpan.finish();
    }
});

// Start the server
const server = app.listen(port, () => {
    console.log(`${serviceName} listening on port ${port}`);
});

// Setup graceful shutdown
setupGracefulShutdown(server);
