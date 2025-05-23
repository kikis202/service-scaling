import http from 'k6/http';
import { check } from 'k6';

export let options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 200,
      stages: [
        { duration: __ENV.PERIOD || '3m', target: 0 },
        { duration: '1m', target: __ENV.PEAK_RATE || 100 },
        { duration: '1m', target: 0 },
      ], // one 5 min cycle: 3m idle, 1m@100rps, 1m ramp-down :contentReference[oaicite:2]{index=2}
    },
  },
};


export default function() {
  const url = __ENV.ENDPOINT || 'http://localhost:8080/echo';
  const body = JSON.parse(__ENV.BODY || '{"test": "value"}');
  const headers = {
    'Content-Type': 'application/json',
    'Host': __ENV.HOST || 'echo-service.default.example.com',
  };
  const res = http.post(url, JSON.stringify(body), { headers });
  check(res, { 'status 200': (r) => r.status === 200 });
}
