import http from 'k6/http';
import { check } from 'k6';

export let options = {
  scenarios: {
    ramping: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 1500,
      stages: [
        { duration: __ENV.DURATION || '12m30s', target: __ENV.MAX_RATE || 500 },
      ],  // ramps from 0→500rps over 12.5 min :contentReference[oaicite:1]{index=1}
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
