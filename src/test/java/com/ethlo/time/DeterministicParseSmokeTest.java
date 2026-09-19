package com.ethlo.time;

/*-
 * #%L
 * Internet Time Utility
 * %%
 * Copyright (C) 2017 Morten Haraldsen (ethlo)
 * %%
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * #L%
 */

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.DateTimeException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.function.Consumer;

import org.junit.jupiter.api.Test;

/**
 * Deterministic parse smoke test used by {@code verify.sh}. The random part uses a fixed seed, so a
 * failure is always reproducible. On failure the minimal failing input is written to
 * {@code target/verify/smoke/minimal-failing-inputs.txt}.
 */
public class DeterministicParseSmokeTest
{
    private static final long SEED = 20261025L;
    private static final int ITERATIONS = 500;
    private static final Path FAILURE_FILE = Paths.get("target", "verify", "smoke", "minimal-failing-inputs.txt");
    private static final char[] ALPHABET = "0123456789-:TZ+.PWTDHMS, z".toCharArray();

    @Test
    void offsets()
    {
        assertThat(ITU.parseDateTime("2024-02-29T23:59:59+14:00").getOffset()).isEqualTo(ZoneOffset.of("+14:00"));
        assertThat(ITU.parseDateTime("2024-02-29T23:59:59-05:30").getOffset()).isEqualTo(ZoneOffset.of("-05:30"));
        assertThat(ITU.parseDateTime("2024-02-29T23:59:59Z").getOffset()).isEqualTo(ZoneOffset.UTC);
        assertThat(ITU.parseDateTime("2024-02-29T23:59:59+00:00").getOffset()).isEqualTo(ZoneOffset.UTC);
    }

    @Test
    void durationTokens()
    {
        final Duration fraction = ITU.parseDuration("PT1.5S");
        assertThat(fraction.getSeconds()).isEqualTo(1);
        assertThat(fraction.getNanos()).isEqualTo(500_000_000);

        assertThat(ITU.parseDuration("PT2H").getSeconds()).isEqualTo(2 * Duration.SECONDS_PER_HOUR);
        assertThat(ITU.parseDuration("P1D").getSeconds()).isEqualTo(Duration.SECONDS_PER_DAY);
        assertThat(ITU.parseDuration("-PT1S").getSeconds()).isEqualTo(-1);
        assertThrows(DateTimeParseException.class, () -> ITU.parseDuration("1D"));
        assertThrows(DateTimeParseException.class, () -> ITU.parseDuration("PT1S1H"));
    }

    @Test
    void leapDays()
    {
        assertThat(ITU.parseDateTime("2024-02-29T00:00:00Z").getDayOfMonth()).isEqualTo(29);
        assertThat(ITU.parseDateTime("2000-02-29T00:00:00Z").getDayOfMonth()).isEqualTo(29);
        assertThrows(DateTimeException.class, () -> ITU.parseDateTime("2023-02-29T00:00:00Z"));
        assertThrows(DateTimeException.class, () -> ITU.parseDateTime("1900-02-29T00:00:00Z"));
    }

    @Test
    void errorPositions()
    {
        final String[] inputs = {"2012-11-11t12:22:", "2012-11-11t12:22:11y", "2012-11-11x", "2012-11-11t12:22:11.1234567890+"};
        for (String input : inputs)
        {
            final DateTimeParseException itu = assertThrows(DateTimeParseException.class, () -> ITU.parseDateTime(input));
            final DateTimeParseException jdk = assertThrows(DateTimeParseException.class, () -> OffsetDateTime.parse(input));
            assertThat(itu.getErrorIndex()).as("error index for %s", input).isEqualTo(jdk.getErrorIndex());
        }
    }

    @Test
    void fixedSeedParseSmoke()
    {
        final Random random = new Random(SEED);
        final List<String> failures = new ArrayList<>();
        for (int i = 0; i < ITERATIONS; i++)
        {
            final String input = randomInput(random);
            check(input, "parseDateTime", ITU::parseDateTime, i, failures);
            check(input, "parseLenient", ITU::parseLenient, i, failures);
            check(input, "parseDuration", ITU::parseDuration, i, failures);
        }

        if (!failures.isEmpty())
        {
            persist(failures);
            throw new AssertionError(failures.size() + " unexpected parser failure(s), minimal inputs saved to " + FAILURE_FILE);
        }
    }

    private static String randomInput(Random random)
    {
        final int length = 1 + random.nextInt(40);
        final StringBuilder sb = new StringBuilder(length);
        for (int i = 0; i < length; i++)
        {
            sb.append(ALPHABET[random.nextInt(ALPHABET.length)]);
        }
        return sb.toString();
    }

    private static void check(String input, String entryPoint, Consumer<String> parser, int iteration, List<String> failures)
    {
        try
        {
            parser.accept(input);
        }
        catch (DateTimeException expected)
        {
            // Rejection is a valid outcome
        }
        catch (RuntimeException | Error unexpected)
        {
            final String minimal = minimize(input, parser, unexpected.getClass());
            failures.add("seed=" + SEED + " iteration=" + iteration + " entryPoint=" + entryPoint
                    + " input=" + quote(input) + " minimal=" + quote(minimal)
                    + " error=" + unexpected.getClass().getName() + ": " + unexpected.getMessage());
        }
    }

    private static String minimize(String input, Consumer<String> parser, Class<? extends Throwable> failureType)
    {
        String current = input;
        boolean shrunk = true;
        while (shrunk && current.length() > 1)
        {
            shrunk = false;
            for (int i = 0; i < current.length(); i++)
            {
                final String candidate = current.substring(0, i) + current.substring(i + 1);
                if (stillFails(candidate, parser, failureType))
                {
                    current = candidate;
                    shrunk = true;
                    break;
                }
            }
        }
        return current;
    }

    private static boolean stillFails(String candidate, Consumer<String> parser, Class<? extends Throwable> failureType)
    {
        try
        {
            parser.accept(candidate);
            return false;
        }
        catch (RuntimeException | Error e)
        {
            return failureType.isInstance(e) && !(e instanceof DateTimeException);
        }
    }

    private static void persist(List<String> failures)
    {
        try
        {
            Files.createDirectories(FAILURE_FILE.getParent());
            Files.write(FAILURE_FILE, failures, StandardCharsets.UTF_8);
        }
        catch (IOException e)
        {
            throw new UncheckedIOException(e);
        }
    }

    private static String quote(String input)
    {
        return '"' + input.replace("\\", "\\\\").replace("\"", "\\\"") + '"';
    }
}
