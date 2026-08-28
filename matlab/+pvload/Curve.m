classdef Curve
% The numbers a cell is judged by, and the figure that shows them.
%
% Magnitudes throughout: which sign the leads produce is a wiring choice
% and papers plot the first quadrant. The CSV keeps what the meters
% reported. Isc and Voc come from the SHORT and OPEN states because that is
% what those states are for, and the flags say when a fallback was used.
% Efficiency is deliberately absent: it needs the incident optical power,
% which the software neither sets nor knows.

methods (Static)

    function stats = summarise(results, cfg)
    % Off the measured columns and nothing else.
    %
    % Isc and Voc come from the SHORT and OPEN states rather than the
    % extremes of the sweep, because that is what those states are for.
    % Neither is a true endpoint: the 470 kohm OPEN path draws a fixed
    % current, so under weak light it stops being an open circuit. Falling
    % back to the measured extreme keeps a partial run useful, and the
    % flags say which happened.

        v  = abs(results.VoltageV);
        i  = abs(results.CurrentA);
        p  = v .* i;
        ok = ~isnan(v) & ~isnan(i);

        stats = struct('Isc', NaN, 'Voc', NaN, 'Pmax', NaN, 'Vmp', NaN, ...
                       'Imp', NaN, 'FillFactor', NaN, ...
                       'AreaCm2', cfg.Cell.AreaCm2, ...
                       'Points', sum(ok), 'Missing', sum(~ok), ...
                       'IscFromEndpoint', false, 'VocFromEndpoint', false, ...
                       'OpenFraction', NaN, 'VocIsFloor', false, ...
                       'PmaxAtEdge', false);

        if ~any(ok)
            return
        end

        short = find(results.Mode == "SHORT" & ok, 1);
        if isempty(short)
            stats.Isc = max(i(ok));
        else
            stats.Isc = i(short);
            stats.IscFromEndpoint = true;
        end

        open = find(results.Mode == "OPEN" & ok, 1);
        if isempty(open)
            stats.Voc = max(v(ok));
        else
            stats.Voc = v(open);
            stats.VocFromEndpoint = true;
        end

        p(~ok) = NaN;
        [stats.Pmax, at] = max(p);
        stats.Vmp = v(at);
        stats.Imp = i(at);

        if stats.Voc > 0 && stats.Isc > 0
            stats.FillFactor = stats.Pmax / (stats.Voc * stats.Isc);
        end

        % Whether the two assumptions above actually hold, decided from the
        % measurement rather than the cell model: the OPEN path draws a
        % current set by Voc while Isc scales with the light, so under weak
        % illumination Voc is a floor and FF inherits the error; and the
        % ladder stops at 10.3 kohm, so a cell whose knee needs more never
        % leaves its current-source region and Pmax is a lower bound.
        % Reporting either without saying so would look like an answer.

        if ~isempty(open) && stats.Isc > 0
            stats.OpenFraction = i(open) / stats.Isc;
            stats.VocIsFloor   = stats.OpenFraction > 0.05;
        end

        ladder = ok & results.Mode ~= "OPEN" & results.Mode ~= "SHORT";
        if any(ladder)
            [~, edge] = max(v .* ladder);
            stats.PmaxAtEdge = at == edge;
        end
    end

    function report(stats)
    % The console gets what the figure carries, in the order a paper lists it.

        if stats.Points == 0
            fprintf("No state returned a reading, so there is no curve.\n");
            return
        end

        guessed = "   (no SHORT state, largest measured)";

        % Console and figure carry the same numbers in the same units, so an
        % area given for one cannot leave the other reporting the other thing.
        if stats.AreaCm2 > 0
            scale = 1e3 / stats.AreaCm2;
            fprintf("\nJsc  %8.3f mA/cm2%s\n", scale * stats.Isc, ...
                Util.ternary(stats.IscFromEndpoint, "", guessed));
        else
            scale = 1e3;
            fprintf("\nIsc  %8.3f mA%s\n", scale * stats.Isc, ...
                Util.ternary(stats.IscFromEndpoint, "", guessed));
        end

        fprintf("Voc  %8.3f V%s\n", stats.Voc, ...
            Util.ternary(stats.VocFromEndpoint, "", ...
                    "   (no OPEN state, largest measured)"));
        fprintf("FF   %8.3f\n", stats.FillFactor);
        fprintf("Pmax %8.3f %s   at Vmp %.3f V, Imp %.3f %s\n", ...
            scale * stats.Pmax, Util.ternary(stats.AreaCm2 > 0, "mW/cm2", "mW"), ...
            stats.Vmp, scale * stats.Imp, ...
            Util.ternary(stats.AreaCm2 > 0, "mA/cm2", "mA"));

        if stats.VocIsFloor
            fprintf("\nThe OPEN state still drew %.1f%% of Isc through the " + ...
                "470 kohm path,\nso Voc is a floor and FF is smaller than " + ...
                "the cell's. More light\nis the fix; nothing in software " + ...
                "reaches it.\n", 100 * stats.OpenFraction);
        end

        if stats.PmaxAtEdge
            fprintf("\nThe largest power in the sweep is the last state of " + ...
                "the ladder, so the\nknee is above 10.3 kohm and outside " + ...
                "what the board can make. Pmax\nis a lower bound, not a " + ...
                "maximum.\n");
        end

        if stats.Missing > 0
            fprintf("%d state(s) returned no reading and are gaps in both.\n", ...
                stats.Missing);
        end
    end

    function draw(results, stats, path)
    % Laid out the way a cell measurement is published: first quadrant,
    % voltage across, current left and power right, Pmax marked and the
    % four numbers in a box. Current density only where CELL_AREA_CM2 gives
    % an area; inventing one would be worse than labelling the axis
    % honestly.
    %
    % Sorted by voltage before the line is drawn, because the sweep is
    % ordered by the resistance model and that model is allowed to be wrong
    % about the order.

        if stats.Points == 0
            return
        end

        scale = 1e3;
        unitI = "mA";
        unitP = "mW";
        label = "Current (mA)";
        if stats.AreaCm2 > 0
            scale = 1e3 / stats.AreaCm2;
            unitI = "mA/cm^2";
            unitP = "mW/cm^2";
            label = "Current density (mA/cm^2)";
        end

        v = abs(results.VoltageV);
        i = scale * abs(results.CurrentA);
        p = scale * abs(results.VoltageV .* results.CurrentA);

        % The ladder gets the line; SHORT and OPEN get markers of their
        % own. The board has no states between the top of the ladder and
        % the 470 kohm OPEN path, so a line joining them would be the most
        % confident-looking part of the figure and the only part with no
        % data under it.

        ladder = results.Mode ~= "SHORT" & results.Mode ~= "OPEN";
        [vl, order] = sort(v(ladder));
        il = i(ladder); il = il(order);
        pl = p(ladder); pl = pl(order);

        fig = figure("Name", "PVLoad I-V curve", "Color", "w", ...
            "Units", "centimeters", "Position", [2 2 16 11]);
        ax = axes(fig);
        hold(ax, "on");

        yyaxis(ax, "left");
        plot(ax, vl, il, "-o", "MarkerSize", 3, "LineWidth", 1.1, ...
            "DisplayName", "load ladder");

        at = results.Mode == "SHORT";
        if any(at)
            plot(ax, v(at), i(at), "d", "MarkerSize", 8, "LineWidth", 1.2, ...
                "MarkerFaceColor", "w", "DisplayName", "SHORT");
        end

        at = results.Mode == "OPEN";
        if any(at)
            plot(ax, v(at), i(at), "^", "MarkerSize", 8, "LineWidth", 1.2, ...
                "MarkerFaceColor", "w", ...
                "DisplayName", Util.ternary(stats.VocIsFloor, ...
                    "OPEN (470 kohm, loaded)", "OPEN"));
        end

        plot(ax, stats.Vmp, scale * stats.Imp, "s", "MarkerSize", 10, ...
            "LineWidth", 1.4, "MarkerFaceColor", "w", ...
            "DisplayName", Util.ternary(stats.PmaxAtEdge, ...
                "largest power (edge of sweep)", "maximum power"));
        ylabel(ax, label);
        ylim(ax, [0 1.1 * scale * stats.Isc]);

        yyaxis(ax, "right");
        plot(ax, vl, pl, "--", "LineWidth", 1.0, "DisplayName", "P-V");
        ylabel(ax, "Power (" + unitP + ")");
        ylim(ax, [0 1.4 * scale * stats.Pmax]);

        yyaxis(ax, "left");
        hold(ax, "off");
        box(ax, "on");
        ax.TickDir = "in";
        ax.LineWidth = 0.8;
        ax.FontSize = 10;
        xlabel(ax, "Voltage (V)");
        xlim(ax, [0 1.05 * stats.Voc]);
        legend(ax, "Location", "southwest", "Box", "off");

        if stats.AreaCm2 > 0
            first = sprintf("J_{sc} = %.3f %s", scale * stats.Isc, unitI);
        else
            first = sprintf("I_{sc} = %.3f mA", 1e3 * stats.Isc);
        end

        % Placed in data coordinates rather than on the figure, so it lands in
        % the same empty region whatever the cell turns out to do. That region
        % is the left of the plot below the plateau: the I-V runs flat along
        % the top until the knee, the P-V climbs from the origin and is still
        % low there, and the legend sits under it in the corner.
        text(ax, 0.04 * stats.Voc, 0.74 * 1.1 * scale * stats.Isc, ...
            {first, ...
             sprintf(Util.ternary(stats.VocIsFloor, ...
                 "V_{oc} > %.3f V", "V_{oc} = %.3f V"), stats.Voc), ...
             sprintf("FF = %.3f", stats.FillFactor), ...
             sprintf("P_{max} = %.3f %s", scale * stats.Pmax, unitP)}, ...
            "VerticalAlignment", "top", "FontSize", 10, ...
            "BackgroundColor", "w", "Margin", 6, ...
            "EdgeColor", [0.15 0.15 0.15]);

        if strlength(path) > 0
            exportgraphics(fig, path, "Resolution", 300);
            fprintf("Plot:     %s\n", path);
        end
    end

    %% =====================================================================
    %  Sweep planning
    %  =====================================================================

end
end
