/* aowlspt_wildspawn.h -- THE ONE WildSpawnType numeric table.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The classification "is this contact a boss, a boss's escort, a cultist, a
 * Raider or a Rogue" was derived twice: once in mods/maps/sp/world.nim by
 * NUMERIC enum value, and once in host/Aowlspt.Host.Il2Cpp/natesp.nim by a
 * case-insensitive SUBSTRING test on the role NAME. The substring test is
 * wrong, and wrong SILENTLY (fact #325, measured):
 *
 *   exUsec  = 24  -- these are the ROGUES. The name contains no "rogue".
 *   pmcBot  =  9  -- these are the RAIDERS. The name contains no "raider",
 *                    and it does contain "pmc", which is a different faction
 *                    from the one the player actually sees.
 *
 * A name-shaped test assigns a faction by SPELLING. Nothing about the name is
 * a contract; the numeric values are, because they are what the client stores
 * in ProfileSettings+0x10. So the table lives here, once, in a header both the
 * host DLL and every mod already have on their include path (tools/aowl.nim
 * adds `-I<repo>/abi` to both), and both callers delegate to it. Two tables
 * that agree today are two tables that disagree after the next enum addition.
 *
 * NOT AN OFFSET FILE. Nothing here dereferences anything. It is pure integer
 * classification over a value the CALLER has already read through its own
 * guarded walk, which is why it is safe to share between two binaries with
 * very different safety envelopes.
 */
#ifndef AOWLSPT_WILDSPAWN_H
#define AOWLSPT_WILDSPAWN_H

/* EPlayerSide. There is no 0 and no 3. */
#define AOWL_SIDE_USEC   1
#define AOWL_SIDE_BEAR   2
#define AOWL_SIDE_SAVAGE 4

/* Returns 1 when the WildSpawnType is a boss, a boss's follower/escort, a
 * cultist, a Raider or a Rogue -- i.e. anything that must NOT sink into the
 * plain-scav bucket even though it is Savage-sided. Values from the enum dump;
 * listing them is longer than a substring test and cannot drift. */
static int aowl_role_is_boss_tier(int role)
{
  switch (role) {
    /* boss* */
    case 2: case 3: case 6: case 7: case 11: case 17: case 22: case 26:
    case 29: case 32: case 36: case 43: case 47: case 65: case 66:
    case 76: case 77:
      return 1;
    /* follower* */
    case 4: case 5: case 8: case 12: case 13: case 14: case 15: case 16:
    case 23: case 27: case 28: case 30: case 33: case 41: case 42:
    case 44: case 45: case 67: case 78:
      return 1;
    /* sectant* -- cultists */
    case 20: case 21: case 39: case 57: case 58: case 59:
      return 1;
    /* pmcBot / pmcBot-alike -- these are the RAIDERS, not PMCs */
    case 9: case 79:
      return 1;
    /* exUsec -- these are the ROGUES */
    case 24:
      return 1;
    default:
      return 0;
  }
}

#endif /* AOWLSPT_WILDSPAWN_H */
