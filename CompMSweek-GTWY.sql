/*
Gateway MarketShare: Takes Market info for Cargo tons, calculates weekly MarketShare for LA and top competitors per Origin-Destination group.
*/

-- WeeklyReport shows info from currentweek- back_weeks (python input)
DECLARE Week0 INT64 DEFAULT EXTRACT(ISOWEEK FROM CURRENT_DATE())-{back_weeks};
-- How many competitors to show per Origins (LA, +4 if NotAsia | + 9 if Asia, others), threshold
DECLARE CompShow INT64 DEFAULT 5;

-- Common table expression, process later forks into two tables based on cookie2 (LA records and all other)
WITH cookie2 AS (
    SELECT 
    CASE 
        -- covid has TipoVuelo excluded 
        WHEN Destino = 'CHILE' THEN CONCAT(Origen, ' - ', Destino, " ", TipoVuelo)
        WHEN Origen = 'USA' AND Destino IN ('LIM') THEN CONCAT(Origen, ' - ', Destino, " ", TipoVuelo)
        ELSE CONCAT(Origen, ' - ', Destino)
    END AS Grupo,
    Owner,
    -- due to two week lag for data from Brasil make each Week (W, WmX) column equal to current week minus 2 for GRU and VCP destinations.
    sum(IF ((RelWeek=week0-0-2 AND Destino IN ('VCP', 'GRU')) OR (Destino NOT IN ('VCP', 'GRU') AND RelWeek=week0-0), Tons, 0)) AS W,
    sum(IF ((RelWeek=week0-1-2 AND Destino IN ('VCP', 'GRU')) OR (Destino NOT IN ('VCP', 'GRU') AND RelWeek=week0-1), Tons, 0)) AS Wm1,
    sum(IF ((RelWeek=week0-2-2 AND Destino IN ('VCP', 'GRU')) OR (Destino NOT IN ('VCP', 'GRU') AND RelWeek=week0-2), Tons, 0)) AS Wm2,
    sum(IF ((RelWeek=week0-3-2 AND Destino IN ('VCP', 'GRU')) OR (Destino NOT IN ('VCP', 'GRU') AND RelWeek=week0-3), Tons, 0)) AS Wm3,
    sum(IF ((RelWeek=week0-4-2 AND Destino IN ('VCP', 'GRU')) OR (Destino NOT IN ('VCP', 'GRU') AND RelWeek=week0-4), Tons, 0)) AS Wm4,
    FROM (
        SELECT 
        Year,
        Semana,
        RelWeek,
        -- define groups according to different origin-destination concepts (GTWY)
        CASE 
            WHEN (RegionOrigenSegmento = 'Europe' AND RegionOrigenAWB IN ('Europe', 'Arfica', 'Asia')) THEN 'EUR'
            WHEN (RegionOrigenSegmento != 'Europe' AND RegionOrigenAWB = 'Europe' AND PaisOrigenSegmento != 'USA') THEN 'EUR'
            WHEN (PaisOrigenSegmento = 'USA' OR (PaisOrigenSegmento != 'USA' AND PaisOrigenAWB = 'USA')) THEN 'USA'
            ELSE 'Otros' 
        END AS Origen,
        -- main destinations for SouthBound flights, Chile and Brasil (GRU, VCP, LIM)
        CASE
            WHEN PaisDestinoAWB IN ('CHILE') Then PaisDestinoAWB
            WHEN PostaDestinoAWB IN ('GRU', 'VCP', 'LIM') Then PostaDestinoAWB
            ELSE 'Otros'
        END AS Destino,
        TipoVuelo,
        TRIM(Owner) AS Owner,
        Tons
        FROM `ReporteWeek.McdoBASE`
    ) cookie
    -- drop unimportant groups
    WHERE Origen != 'Otros' AND Destino != 'Otros'
    GROUP BY 1,2
    ORDER BY 1,3 DESC
),
/*
Here we split cookie2 into two tables: 
    1. cookie3LA: filter Owner='LA', will later be given Rank0 (LA to appear first)
    2. cookie3: all the other Owners, later will be split in two as well (OwnerGrpd 'Otros' vs the rest, as 'Otros' always wants to be shown last)

This id done to always show the 'LA' and 'Otros' groupings in our final table no matter their MarketShare
*/
cookie3 AS (
    SELECT 
    *,
    CASE
        WHEN ROW_NUMBER() OVER (PARTITION BY Grupo ORDER BY W DESC) >= CompShow Then 'Otros'
        ELSE Owner
    END AS OwnerGrpd
    FROM cookie2
    WHERE Owner != 'LA'
),
cookie3LA AS (
    SELECT 
    *,
    Owner AS OwnerGrpd
    FROM cookie2
    WHERE Owner = 'LA'
)

SELECT
CONCAT(CAST(Rank AS STRING), Grupo) AS excelKEY, -- (used for vlookup in excel)
Rank,
Grupo,
OwnerGrpd,
 -- Calculate MS per each week, assigns record to NULL if zero division
IEEE_DIVIDE(W, sum(W) OVER (PARTITION BY Grupo)) AS Wr,
IEEE_DIVIDE(Wm1, sum(Wm1) OVER (PARTITION BY Grupo)) AS Wm1r,
IEEE_DIVIDE(Wm2, sum(Wm2) OVER (PARTITION BY Grupo)) AS Wm2r,
IEEE_DIVIDE(Wm3, sum(Wm3) OVER (PARTITION BY Grupo)) AS Wm3r,
IEEE_DIVIDE(Wm4, sum(Wm4) OVER (PARTITION BY Grupo)) AS Wm4r,
W,
Wm1,
Wm2,
Wm3,
Wm4
FROM (

    /*
    LA is ranked as 0, Otros as 99, all other owners are ranked according to last week's tons (W) per Grupo and tagged as 'Otros' if 
    ranked below threshold. Both tables are then appended to each other.
    */
    
    SELECT 
    ROW_NUMBER() OVER (PARTITION BY Grupo ORDER BY sum(W) DESC) AS Rank,
    Grupo,
    OwnerGrpd,
    sum(W) as W,
    sum(Wm1) as Wm1,
    sum(Wm2) as Wm2,
    sum(Wm3) as Wm3,
    sum(Wm4) as Wm4
    FROM cookie3
    WHERE OwnerGrpd != 'Otros'
    GROUP BY 2,3

    UNION ALL
    
    -- Otros assign rank to 99 (always last in list yet included)  
    SELECT 
    99 AS Rank,
    Grupo,
    OwnerGrpd,
    sum(W) as W,
    sum(Wm1) as Wm1,
    sum(Wm2) as Wm2,
    sum(Wm3) as Wm3,
    sum(Wm4) as Wm4
    FROM cookie3
    WHERE OwnerGrpd = 'Otros'
    GROUP BY 2,3

    UNION ALL

    SELECT 
    0 AS Rank,
    Grupo,
    OwnerGrpd,
    sum(W) as W,
    sum(Wm1) as Wm1,
    sum(Wm2) as Wm2,
    sum(Wm3) as Wm3,
    sum(Wm4) as Wm4
    FROM cookie3LA
    GROUP BY 2,3

) FinalCookie
ORDER BY 3, 2
