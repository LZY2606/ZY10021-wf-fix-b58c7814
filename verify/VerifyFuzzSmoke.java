import java.io.File;
import java.time.DateTimeException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

import com.ethlo.time.Duration;
import com.ethlo.time.ITU;
import com.ethlo.time.LeapSecondException;

/**
 * Fixed-seed parser smoke test, executed directly against the packaged classes by
 * {@code verify.sh}. It is intentionally small and deterministic (no network, no external
 * dependencies): the pseudo-random generator is seeded with {@link #SEED}, so the same commit
 * always exercises the same inputs.
 *
 * <p>Coverage buckets:
 * <ul>
 *     <li>{@code offset} - RFC-3339 date-times with generated UTC / hour / hour-minute offsets</li>
 *     <li>{@code duration-token} - ISO-8601 duration tokens (P/T/D/H/M/S/W and fractions)</li>
 *     <li>{@code leap-day} - February 29 and end-of-field-range semantic validation</li>
 *     <li>{@code error-position} - malformed inputs whose error index must match the JDK parser</li>
 *     <li>{@code crash-canary} - seeded random garbage: only unexpected exceptions are findings</li>
 * </ul>
 *
 * <p>A mismatch between the ITU parser and the JDK reference parser is a finding. Every finding is
 * delta-debugged to a minimal input and written to {@code findings/}; the process exits non-zero
 * and prints the minimized inputs so that the failure can be reproduced without re-fuzzing.
 */
public final class VerifyFuzzSmoke
{
    static final long SEED = 0x5EED1741L;

    private static final int RANDOM_DATETIMES = 160;
    private static final int RANDOM_DURATIONS = 120;
    private static final int RANDOM_GARBAGE = 120;

    private static final String OFFSET_CHARS = "0123456789TtZzPp:.,+- \t/";
    private static final String DURATION_CHARS = "0123456789PTWDHMS.,-+ ";

    private final List<Finding> findings = new ArrayList<>();
    private final Map<String, long[]> counters = new LinkedHashMap<>();
    private final File findingsDir;

    private VerifyFuzzSmoke(final File findingsDir)
    {
        this.findingsDir = findingsDir;
        for (final String bucket : new String[]{
                "offset", "duration-token", "leap-day", "error-position", "crash-canary"})
        {
            counters.put(bucket, new long[2]);
        }
    }

    public static void main(final String[] args) throws IOException
    {
        if (args.length != 1)
        {
            System.err.println("usage: VerifyFuzzSmoke <findings-dir>");
            System.exit(2);
        }
        final File findingsDir = new File(args[0]);
        Files.createDirectories(findingsDir.toPath());
        final VerifyFuzzSmoke smoke = new VerifyFuzzSmoke(findingsDir);
        smoke.run();
        smoke.report();
        if (!smoke.findings.isEmpty())
        {
            // 14 = parser disagreement; verify.sh documents and preserves this code.
            System.exit(14);
        }
    }

    private void run() throws IOException
    {
        final Random random = new Random(SEED);

        // Bucket 1: offset token coverage - every generated input is valid RFC-3339 and must agree
        // with java.time.OffsetDateTime, including the instant represented by the offset.
        for (int i = 0; i < RANDOM_DATETIMES; i++)
        {
            final String input = randomValidDateTime(random);
            checkOffset(input);
        }
        checkOffset("2024-02-29T12:30:30+01:30");
        checkOffset("2024-02-29T12:30:30-12:00");
        checkOffset("2024-12-31T23:59:59.123456789Z");
        checkOffset("2000-02-29T00:00:00+00:00");
        checkOffset("2024-06-15T08:15:01.5Z");

        // Bucket 2: duration token coverage over the token alphabet ITU documents as supported.
        for (int i = 0; i < RANDOM_DURATIONS; i++)
        {
            checkDuration(randomValidDuration(random));
        }
        checkDuration("PT5M30S");
        checkDuration("P2DT3H4M5.678901234S");
        checkDuration("-PT2.5S");
        checkDuration("-P1D");
        checkDuration("PT0.5S");
        checkDuration("P0D");

        // Bucket 3: leap day and semantic field-range validation. Both parsers must reject the
        // invalid cases; valid leap days (including year 2000, excluding 1900) must parse equally.
        checkLeapDay("2024-02-29T23:59:59Z", true);
        checkLeapDay("2000-02-29T00:00:00Z", true);
        checkLeapDay("2023-02-29T00:00:00Z", false);
        checkLeapDay("1900-02-29T00:00:00Z", false);
        checkLeapDay("2024-02-30T00:00:00Z", false);
        checkLeapDay("2024-13-01T00:00:00Z", false);
        checkLeapDay("2024-04-31T00:00:00Z", false);
        checkLeapDay("2024-01-01T25:00:00Z", false);
        checkLeapDay("2024-01-01T12:60:00Z", false);
        checkLeapDay("2024-01-01T12:00:61Z", false);
        checkLeapSecond("1990-12-31T23:59:60Z", "1991-01-01T00:00:00Z", true);
        checkLeapSecond("1992-06-30T23:59:60Z", "1992-07-01T00:00:00Z", true);
        checkLeapSecond("1990-12-31T15:59:60-08:00", "1991-01-01T00:00:00Z", true);
        checkLeapSecond("2032-06-30T15:59:60-08:00", "2032-07-01T00:00:00Z", false);

        // Bucket 4: error position - the fixed corpus from ErrorOffsetTest guarantees the reported
        // error index is identical to java.time.
        final String[] errorPositionCases = {
                "111", "1111-", "2012-2", "2012-11-", "2012-11-1", "2012-11-11x",
                "2012-11-11t12", "2012-11-11t12:", "2012-11-11t12:22", "2012-11-11t12:22:",
                "2012-11-11t12:22:1", "2012-11-11t12:22:11", "2012-11-11t12:22:11y",
                "2012-11-11t12:22:11.1234567890", "2012-11-11t12:22:11.1234567890+",
                "2012-11-11t12:22:11.1234567890+8", "2012-11-11t12:22:11.1234567890+08:",
                "2012-11-11t12:22:11.1234567890+08:1", "2012-11-11t12:22:11.1234567890+08:11x"};
        for (final String input : errorPositionCases)
        {
            checkErrorPosition(input);
        }

        // Bucket 5: seeded random garbage. Random strings have no oracle for "correct" rejection,
        // so only unexpected exceptions (anything outside java.time.DateTimeException) are
        // findings - this guards against crashes on arbitrary bytes.
        for (int i = 0; i < RANDOM_GARBAGE; i++)
        {
            checkCrashCanary(randomString(random, OFFSET_CHARS, 40), false);
            checkCrashCanary(randomString(random, DURATION_CHARS, 40), true);
        }
    }

    private void checkOffset(final String input)
    {
        record("offset");
        try
        {
            final OffsetDateTime itu = ITU.parseDateTime(input);
            final OffsetDateTime jdk;
            try
            {
                jdk = OffsetDateTime.parse(input);
            }
            catch (DateTimeException jdkFailure)
            {
                mismatch("offset", input, "ITU accepted: " + itu, "JDK rejected: " + jdkFailure.getMessage());
                return;
            }
            if (!itu.toInstant().equals(jdk.toInstant()) || !itu.equals(jdk))
            {
                mismatch("offset", input, "ITU=" + itu, "JDK=" + jdk);
            }
        }
        catch (DateTimeException ituFailure)
        {
            if (isJdkAccepted(input))
            {
                mismatch("offset", input, "ITU rejected: " + ituFailure.getMessage(), "JDK accepted");
            }
        }
    }

    private void checkDuration(final String input)
    {
        record("duration-token");
        boolean ituOk;
        Duration ituDuration = null;
        try
        {
            ituDuration = ITU.parseDuration(input);
            ituOk = true;
        }
        catch (DateTimeException e)
        {
            ituOk = false;
        }
        boolean jdkOk;
        java.time.Duration jdkDuration = null;
        try
        {
            jdkDuration = java.time.Duration.parse(input);
            jdkOk = true;
        }
        catch (DateTimeException e)
        {
            jdkOk = false;
        }
        if (ituOk != jdkOk)
        {
            mismatch("duration-token", input,
                    ituOk ? "ITU accepted: " + ituDuration : "ITU rejected",
                    jdkOk ? "JDK accepted: " + jdkDuration : "JDK rejected");
            return;
        }
        if (ituOk && (ituDuration.getSeconds() != jdkDuration.getSeconds()
                || ituDuration.getNanos() != jdkDuration.getNano()))
        {
            mismatch("duration-token", input, "ITU=" + ituDuration, "JDK=" + jdkDuration);
        }
    }

    private void checkLeapDay(final String input, final boolean expectedValid)
    {
        record("leap-day");
        boolean ituValid;
        try
        {
            ITU.parseDateTime(input);
            ituValid = true;
        }
        catch (DateTimeException e)
        {
            ituValid = false;
        }
        if (ituValid != expectedValid || isJdkAccepted(input) != expectedValid)
        {
            mismatch("leap-day", input,
                    "ITU " + (ituValid ? "accepted" : "rejected")
                            + " / JDK " + (isJdkAccepted(input) ? "accepted" : "rejected"),
                    "expected " + (expectedValid ? "valid" : "invalid")
                            + " (common-year/February/field-range rule)");
        }
    }

    private void checkLeapSecond(final String input, final String expectedUtc,
                                 final boolean verifiedLeap)
    {
        record("leap-day");
        try
        {
            ITU.parseDateTime(input);
            mismatch("leap-day", input, "ITU accepted without LeapSecondException",
                    "expected LeapSecondException nearest " + expectedUtc);
            return;
        }
        catch (LeapSecondException e)
        {
            final String actualUtc = ITU.formatUtc(e.getNearestDateTime());
            if (!expectedUtc.equals(actualUtc)
                    || e.getSecondsInMinute() != 60
                    || e.isVerifiedValidLeapYearMonth() != verifiedLeap)
            {
                mismatch("leap-day", input, "nearest=" + actualUtc
                                + ", seconds=" + e.getSecondsInMinute()
                                + ", verified=" + e.isVerifiedValidLeapYearMonth(),
                        "nearest=" + expectedUtc + ", seconds=60, verified=" + verifiedLeap);
            }
        }
        catch (DateTimeException e)
        {
            mismatch("leap-day", input, "ITU rejected: " + e.getMessage(),
                    "expected LeapSecondException nearest " + expectedUtc);
        }
        if (isJdkAccepted(input))
        {
            mismatch("leap-day", input, "JDK accepted leap second", "JDK must reject second=60");
        }
    }

    private void checkErrorPosition(final String input)
    {
        record("error-position");
        final Integer ituIndex = ituErrorIndex(input);
        Integer jdkIndex = null;
        try
        {
            OffsetDateTime.parse(input);
        }
        catch (DateTimeParseException e)
        {
            jdkIndex = e.getErrorIndex();
        }
        if (ituIndex == null)
        {
            mismatch("error-position", input, "ITU accepted", "JDK rejected@" + jdkIndex);
        }
        else if (jdkIndex == null)
        {
            mismatch("error-position", input, "ITU rejected@" + ituIndex, "JDK accepted");
        }
        else if (!ituIndex.equals(jdkIndex))
        {
            mismatch("error-position", input, "ITU errorIndex=" + ituIndex,
                    "JDK errorIndex=" + jdkIndex);
        }
    }

    private Integer ituErrorIndex(final String input)
    {
        try
        {
            ITU.parseDateTime(input);
            return null;
        }
        catch (DateTimeParseException e)
        {
            return e.getErrorIndex();
        }
        catch (DateTimeException e)
        {
            return -1;
        }
    }

    private void checkCrashCanary(final String input, final boolean duration)
    {
        record("crash-canary");
        try
        {
            if (duration)
            {
                ITU.parseDuration(input);
            }
            else
            {
                ITU.parseLenient(input);
            }
        }
        catch (DateTimeException expected)
        {
            // Documented exception family - a parser is allowed to reject random input.
        }
        catch (RuntimeException e)
        {
            mismatch("crash-canary", input, "unexpected " + e.getClass().getName(),
                    "only java.time.DateTimeException allowed");
        }
    }

    private static String randomValidDateTime(final Random random)
    {
        final int year = 1 + random.nextInt(9999);
        final int month = 1 + random.nextInt(12);
        int maxDay;
        switch (month)
        {
            case 2:
                maxDay = ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 29 : 28;
                break;
            case 4:
            case 6:
            case 9:
            case 11:
                maxDay = 30;
                break;
            default:
                maxDay = 31;
        }
        final int day = 1 + random.nextInt(maxDay);
        final int hour = random.nextInt(24);
        final int minute = random.nextInt(60);
        final int second = random.nextInt(60);
        final StringBuilder sb = new StringBuilder();
        sb.append(String.format("%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second));
        if (random.nextInt(4) == 0)
        {
            final int digits = 1 + random.nextInt(9);
            sb.append('.');
            for (int i = 0; i < digits; i++)
            {
                sb.append((char) ('0' + random.nextInt(10)));
            }
        }
        if (random.nextBoolean())
        {
            sb.append('Z');
        }
        else
        {
            final int offsetHours = random.nextInt(19);
            final int offsetMinutes = offsetHours == 18 ? 0 : random.nextInt(60);
            sb.append(String.format("%s%02d:%02d", random.nextBoolean() ? "+" : "-",
                    offsetHours, offsetMinutes));
        }
        return sb.toString();
    }

    private static String randomValidDuration(final Random random)
    {
        StringBuilder sb = new StringBuilder();
        if (random.nextBoolean())
        {
            sb.append('-');
        }
        sb.append('P');
        // A mix of value/unit tokens from the alphabet ITU supports. Java accepts D/H/M/S but
        // rejects W, so week tokens are excluded from this randomized cross-check stream.
        if (random.nextBoolean())
        {
            sb.append(1 + random.nextInt(30)).append('D');
        }
        if (random.nextBoolean())
        {
            sb.append('T');
            if (random.nextBoolean())
            {
                sb.append(random.nextInt(24)).append('H');
            }
            if (random.nextBoolean())
            {
                sb.append(random.nextInt(60)).append('M');
            }
            if (random.nextBoolean() || sb.charAt(sb.length() - 1) == 'T')
            {
                sb.append(random.nextInt(60));
                if (random.nextInt(3) == 0)
                {
                    sb.append('.');
                    final int digits = 1 + random.nextInt(9);
                    for (int i = 0; i < digits; i++)
                    {
                        sb.append((char) ('0' + random.nextInt(10)));
                    }
                }
                sb.append('S');
            }
        }
        return sb.toString();
    }

    private static String randomString(final Random random, final String alphabet, final int maxLen)
    {
        final int len = random.nextInt(maxLen + 1);
        final StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++)
        {
            sb.append(alphabet.charAt(random.nextInt(alphabet.length())));
        }
        return sb.toString();
    }

    private static boolean isJdkAccepted(final String input)
    {
        try
        {
            OffsetDateTime.parse(input);
            return true;
        }
        catch (DateTimeException e)
        {
            return false;
        }
    }

    private void record(final String bucket)
    {
        counters.get(bucket)[0]++;
    }

    private void mismatch(final String bucket, final String input, final String itu, final String expected)
    {
        counters.get(bucket)[1]++;
        final String minimized = minimize(bucket, input);
        findings.add(new Finding(bucket, minimized, itu, expected));
    }

    /**
     * Delta-debugging minimizer: repeatedly tries removing each single character while the
     * mismatch still reproduces, until no character can be removed. Produces a smallest failing
     * input for the same bucket, not necessarily the global minimum, which is sufficient for a
     * deterministic smoke test.
     */
    private String minimize(final String bucket, final String failing)
    {
        String current = failing;
        boolean shrunk = true;
        int guard = 0;
        while (shrunk && guard++ < 64)
        {
            shrunk = false;
            for (int i = 0; i < current.length(); i++)
            {
                final String candidate = current.substring(0, i) + current.substring(i + 1);
                if (reproduces(bucket, candidate))
                {
                    current = candidate;
                    shrunk = true;
                    break;
                }
            }
        }
        return current;
    }

    private boolean reproduces(final String bucket, final String input)
    {
        final VerifyFuzzSmoke probe = new VerifyFuzzSmoke(findingsDir);
        switch (bucket)
        {
            case "offset":
                probe.checkOffsetSilently(input);
                break;
            case "duration-token":
                probe.checkDuration(input);
                break;
            case "leap-day":
                probe.checkLeapDaySilently(input);
                break;
            case "error-position":
                probe.checkErrorPosition(input);
                break;
            case "crash-canary":
                probe.checkCrashCanary(input, false);
                probe.checkCrashCanary(input, true);
                break;
            default:
                return false;
        }
        return !probe.findings.isEmpty();
    }

    private void checkOffsetSilently(final String input)
    {
        try
        {
            final OffsetDateTime itu = ITU.parseDateTime(input);
            if (!isJdkAccepted(input))
            {
                findings.add(new Finding("offset", input, "", ""));
            }
            else
            {
                final OffsetDateTime jdk = OffsetDateTime.parse(input);
                if (!itu.toInstant().equals(jdk.toInstant()))
                {
                    findings.add(new Finding("offset", input, "", ""));
                }
            }
        }
        catch (DateTimeException e)
        {
            if (isJdkAccepted(input))
            {
                findings.add(new Finding("offset", input, "", ""));
            }
        }
    }

    private void checkLeapDaySilently(final String input)
    {
        if (input.indexOf(":59:60") >= 0)
        {
            // Leap-second predicate: ITU must surface LeapSecondException carrying second 60 and
            // the expected nearest instant/verified flag (recomputed from the input).
            boolean leapSeen = false;
            try
            {
                ITU.parseDateTime(input);
            }
            catch (LeapSecondException e)
            {
                final String expectedUtc = expectedLeapNearest(input);
                leapSeen = e.getSecondsInMinute() == 60
                        && expectedUtc != null
                        && expectedUtc.equals(ITU.formatUtc(e.getNearestDateTime()))
                        && e.isVerifiedValidLeapYearMonth() == expectedVerifiedLeap(input);
            }
            catch (DateTimeException e)
            {
                leapSeen = false;
            }
            if (!leapSeen)
            {
                findings.add(new Finding("leap-day", input, "", ""));
            }
            return;
        }
        boolean ituValid;
        try
        {
            ITU.parseDateTime(input);
            ituValid = true;
        }
        catch (DateTimeException e)
        {
            ituValid = false;
        }
        if (ituValid != isJdkAccepted(input))
        {
            findings.add(new Finding("leap-day", input, "", ""));
        }
    }

    private static String expectedLeapNearest(final String input)
    {
        try
        {
            final String with59 = input.replace(":59:60", ":59:59");
            return ITU.formatUtc(OffsetDateTime.parse(with59).plusSeconds(1));
        }
        catch (DateTimeException e)
        {
            return null;
        }
    }

    private static boolean expectedVerifiedLeap(final String input)
    {
        return input.startsWith("1990-12-31") || input.startsWith("1992-06-30");
    }

    private void report() throws IOException
    {
        System.out.println("parser-fuzz-smoke: seed=0x" + Long.toHexString(SEED)
                + " deterministic=true");
        long total = 0;
        long totalFindings = 0;
        for (final Map.Entry<String, long[]> entry : counters.entrySet())
        {
            final long checked = entry.getValue()[0];
            final long mismatches = entry.getValue()[1];
            total += checked;
            totalFindings += mismatches;
            System.out.printf("parser-fuzz-smoke: bucket=%-15s inputs=%d findings=%d%n",
                    entry.getKey(), checked, mismatches);
        }
        System.out.println("parser-fuzz-smoke: total-inputs=" + total
                + " total-findings=" + totalFindings);
        int index = 0;
        for (final Finding finding : findings)
        {
            final String file = String.format("finding-%02d-%s.txt", index + 1, finding.bucket);
            final String body = "bucket: " + finding.bucket + System.lineSeparator()
                    + "input: " + finding.input + System.lineSeparator()
                    + "itu: " + finding.itu + System.lineSeparator()
                    + "expected: " + finding.expected + System.lineSeparator();
            Files.write(new File(findingsDir, file).toPath(),
                    body.getBytes(StandardCharsets.UTF_8));
            System.out.println("parser-fuzz-smoke: MINIMAL FAILING INPUT [" + finding.bucket
                    + "] " + finding.input);
            index++;
        }
        if (!findings.isEmpty())
        {
            System.out.println("parser-fuzz-smoke: minimized findings written to "
                    + findingsDir.getPath());
        }
    }

    private static final class Finding
    {
        private final String bucket;
        private final String input;
        private final String itu;
        private final String expected;

        private Finding(final String bucket, final String input, final String itu,
                        final String expected)
        {
            this.bucket = bucket;
            this.input = input;
            this.itu = itu;
            this.expected = expected;
        }
    }
}
