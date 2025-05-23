import http from 'k6/http';
import { check } from 'k6';

export let options = {
  scenarios: {
    constant: {
      executor: 'constant-arrival-rate',
      rate: __ENV.RATE ? parseInt(__ENV.RATE) : 10,        // requests per second
      timeUnit: '1s',
      duration: __ENV.DURATION || '10m',                  // default 10 minutes :contentReference[oaicite:0]{index=0}
      preAllocatedVUs: 50,
      maxVUs: 100,
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
