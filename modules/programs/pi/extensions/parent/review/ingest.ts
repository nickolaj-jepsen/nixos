/**
 * Reading tuicr's sessions back: which sessions belong to this repository and
 * this pi session (D6), and which of their comments are new (C4).
 *
 * Until A3 fills this in, a session start ingests nothing.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";

export const ingestReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {};
