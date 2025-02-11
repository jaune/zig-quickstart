/**
 * @import {GithubScriptContext} from "./github-script-types.ts"
 */

import { readFile } from 'fs/promises'

const HEAD_REF_PREFIX = 'refs/heads/'

// @ts-check
/** @param {GithubScriptContext} context */
export default async function ({ core, context }) {
  try {
    const short_sha = context.sha.substring(0, 9)

    if (!context.ref.startsWith(HEAD_REF_PREFIX)) {
      throw new Error('unable to resolved branch name')
    }

    const branch_name = context.ref.substring(HEAD_REF_PREFIX.length);

    core.setOutput('short-sha', short_sha)
    core.setOutput('branch-name', branch_name)

    const zig_version = (await readFile('./.zig-version', { encoding: 'utf-8' })).trim()

    core.setOutput('zig-version', zig_version)

    const zonString = await readFile('./build.zig.zon', { encoding: 'utf-8' })
    const zonMatches = zonString.match(/\.version \= \"([0-9]+\.[0-9]+\.[0-9]+)\"/)
    const buildZigZonVersion = (zonMatches && typeof zonMatches[1] === 'string') ? zonMatches[1] : null

    if (!buildZigZonVersion) {
      throw new Error('unable to find version in build.zig.zon')
    }

    core.setOutput('build-zig-zon-version', buildZigZonVersion)

    const runAttempt = parseInt(process.env.GITHUB_RUN_ATTEMPT || '1', 10)
    const runNumber = parseInt(process.env.GITHUB_RUN_NUMBER || '1', 10)

    if (context.runAttempt > 200) {
      throw new Error('too many attempt')
    }

    const run_number_and_attempt = runNumber.toString(8) + runAttempt.toString(8).padStart(2, '0')

    const release_tag = `${buildZigZonVersion}-${branch_name}.${run_number_and_attempt}+${short_sha}`

    core.setOutput('release-tag', release_tag)

  } catch(err) {
    core.error('Error while computing variables.')
    core.setFailed(err)
  }
}
