using System;

namespace Aowl.Api
{
    /// <summary>
    /// Float samples in, 16 kHz mono 16-bit little-endian PCM out -- the ONE
    /// format /speech/chunk accepts (CLIENT-CONTRACT section 3: "there is no
    /// resampling anywhere in this system"; whisper.cpp will not resample).
    ///
    /// Pure C#, no Unity: the offline harness (spt/ChunkCheck) compiles this
    /// same file, so what it measures is what the plugin ships.
    ///
    /// Linear interpolation with the fractional read position and the last
    /// source sample carried ACROSS pushes, so a 250 ms chunk boundary is not
    /// audible as a click and the output length over a session is exactly
    /// dstRate/srcRate of the input, not one sample short per chunk.
    /// </summary>
    public sealed class Resampler
    {
        /// <summary>Source and destination sample rates, Hz.</summary>
        public readonly int SrcRate, DstRate;
        private readonly double _step;      // source samples per output sample
        private double _pos;                // fractional position into the virtual [prev, chunk...] stream
        private float _prev;                // the last sample of the previous push
        private bool _havePrev;
        /// <summary>Running totals over the life of this instance.</summary>
        public long SamplesIn, SamplesOut;

        /// <summary>A resampler from <paramref name="srcRate"/> to <paramref name="dstRate"/>; equal rates pass straight through.</summary>
        public Resampler(int srcRate, int dstRate)
        {
            if (srcRate <= 0 || dstRate <= 0) throw new ArgumentOutOfRangeException("rate");
            SrcRate = srcRate; DstRate = dstRate;
            _step = (double)srcRate / dstRate;
        }

        /// <summary>Converts `count` samples of `src` to PCM16 bytes at DstRate.</summary>
        public byte[] Push(float[] src, int count)
        {
            if (count <= 0) return new byte[0];
            SamplesIn += count;
            if (SrcRate == DstRate)
            {
                var direct = new byte[count * 2];
                for (int i = 0; i < count; i++) Pack(src[i], direct, i * 2);
                SamplesOut += count;
                return direct;
            }
            // Virtual stream: index 0 is _prev (when present), 1.. are src[0..].
            int baseCount = (_havePrev ? 1 : 0) + count;
            // Output samples whose interpolation window [floor, floor+1] lies inside the stream.
            int outMax = (int)Math.Floor((baseCount - 1 - _pos) / _step) + 1;
            if (outMax < 0) outMax = 0;
            var o = new byte[outMax * 2];
            int n = 0;
            double p = _pos;
            for (; n < outMax; n++)
            {
                int i0 = (int)Math.Floor(p);
                double frac = p - i0;
                float a = At(src, i0), b = At(src, i0 + 1);
                Pack((float)(a + (b - a) * frac), o, n * 2);
                p += _step;
            }
            // Carry: the new stream starts at the last source sample.
            _pos = p - (baseCount - 1);
            _prev = src[count - 1];
            _havePrev = true;
            SamplesOut += n;
            if (n * 2 == o.Length) return o;
            var trimmed = new byte[n * 2];
            Array.Copy(o, trimmed, n * 2);
            return trimmed;
        }

        private float At(float[] src, int vi)
        {
            if (_havePrev) { if (vi == 0) return _prev; vi--; }
            if (vi < 0) vi = 0;
            if (vi >= src.Length) vi = src.Length - 1;
            return src[vi];
        }

        /// <summary>Clamp a float sample to [-1,1] and write it as little-endian int16 at <paramref name="at"/>.</summary>
        public static void Pack(float v, byte[] dst, int at)
        {
            if (v > 1f) v = 1f; else if (v < -1f) v = -1f;
            short s = (short)Math.Round(v * 32767f);
            dst[at] = (byte)(s & 0xff);
            dst[at + 1] = (byte)((s >> 8) & 0xff);
        }

        /// <summary>A 44-byte RIFF header for PCM16; used by the harness and by the cache writer.</summary>
        public static byte[] RiffHeader(int dataLen, int rate, int channels)
        {
            var h = new byte[44];
            void S(int at, string s) { for (int i = 0; i < 4; i++) h[at + i] = (byte)s[i]; }
            void L32(int at, int v) { h[at] = (byte)v; h[at + 1] = (byte)(v >> 8); h[at + 2] = (byte)(v >> 16); h[at + 3] = (byte)(v >> 24); }
            void L16(int at, int v) { h[at] = (byte)v; h[at + 1] = (byte)(v >> 8); }
            S(0, "RIFF"); L32(4, 36 + dataLen); S(8, "WAVE"); S(12, "fmt "); L32(16, 16); L16(20, 1); L16(22, channels);
            L32(24, rate); L32(28, rate * channels * 2); L16(32, channels * 2); L16(34, 16); S(36, "data"); L32(40, dataLen);
            return h;
        }
    }
}
